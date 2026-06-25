/*
 * SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

use std::borrow::Cow;
use std::sync::Arc;

use bmc_vendor::BMCVendor;
use carbide_utils::arch::CpuArchitecture;
use rpc::machine_discovery::{DiscoveryInfo, DmiData};
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::{BootOptionKind, Callbacks, hw, redfish};

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum CiscoGpuProfile {
    #[default]
    MgxPcie,
    HgxSxm,
}

pub struct CiscoUcs<'a> {
    pub product: Cow<'a, str>,
    pub gpu_profile: CiscoGpuProfile,
    pub product_serial_number: Cow<'a, str>,
    pub nics: Vec<(hw::nic::SlotNumber, hw::nic::Nic<'a>)>,
}

impl CiscoUcs<'_> {
    pub fn manager_config(&self) -> redfish::manager::Config {
        redfish::manager::Config {
            managers: vec![redfish::manager::SingleConfig {
                id: "bmc",
                eth_interfaces: Some(vec![]),
                host_interfaces: Some(vec![]),
                firmware_version: Some("2.0(2.260062)"),
                oem: None,
            }],
        }
    }

    pub fn system_config(&self, callbacks: Arc<dyn Callbacks>) -> redfish::computer_system::Config {
        let system_id = "system";

        let eth_interfaces = self
            .nics
            .iter()
            .map(|(slot_number, nic)| {
                let eth_id = format!("NIC.P{slot_number}-1");
                let resource = redfish::ethernet_interface::system_resource(system_id, &eth_id);
                redfish::ethernet_interface::builder(&resource)
                    .description(&format!("Nvidia Network Adapter - {}", nic.mac_address))
                    .mac_address(nic.mac_address)
                    .interface_enabled(true)
                    .build()
            })
            .collect();

        let boot_opt_builder = |id: &str, kind| {
            redfish::boot_option::builder(&redfish::boot_option::resource(system_id, id), kind)
                .boot_option_reference(id)
        };
        let boot_options = self
            .nics
            .iter()
            .map(|(slot_number, nic)| {
                (
                    format!(
                        "UEFI P{slot_number}: HTTP IPv4 Nvidia Network Adapter - {}",
                        nic.mac_address
                    ),
                    BootOptionKind::Network,
                )
            })
            .chain(std::iter::once((
                "UEFI OS".to_string(),
                BootOptionKind::Disk,
            )))
            .enumerate()
            .map(|(index, (display_name, kind))| {
                boot_opt_builder(&format!("Boot{index:04X}"), kind)
                    .display_name(&display_name)
                    .build()
            })
            .collect();

        let mut chassis: Vec<Cow<'static, str>> = vec!["chassis".into()];
        if self.gpu_profile == CiscoGpuProfile::HgxSxm {
            chassis.push("nvswitch".into());
            for index in 0..8 {
                chassis.push(format!("gpu_{index}").into());
            }
        }

        redfish::computer_system::Config {
            systems: vec![redfish::computer_system::SingleSystemConfig {
                id: Cow::Borrowed(system_id),
                manufacturer: Some("Cisco Systems Inc".into()),
                model: Some(self.product.to_string().into()),
                eth_interfaces: Some(eth_interfaces),
                serial_number: Some(self.product_serial_number.to_string().into()),
                boot_order_mode: redfish::computer_system::BootOrderMode::Generic,
                callbacks: Some(callbacks),
                chassis,
                boot_options: Some(boot_options),
                bios_mode: redfish::computer_system::BiosMode::Generic,
                oem: redfish::computer_system::Oem::Generic,
                log_services: None,
                storage: None,
                base_bios: Some(
                    redfish::bios::builder(&redfish::bios::resource(system_id))
                        .attributes(json!({
                            "NWSK000": "Enabled",
                            "NWSK001": "Enabled",
                            "NWSK006": "Enabled",
                            "NWSK002": "Disabled",
                            "NWSK007": "Disabled",
                            "TER001": "Enabled",
                            "TER010": "Enabled",
                            "TER06B": "COM0",
                            "TER0021": "115200",
                            "TER0020": "115200",
                            "TER012": "ANSI",
                            "TER011": "VT-UTF8",
                            "TER05D": "None",
                        }))
                        .build(),
                ),
                secure_boot_available: false,
            }],
        }
    }

    pub fn chassis_config(&self) -> redfish::chassis::ChassisConfig {
        let chassis_id = "chassis";

        let mut pcie_devices = self
            .nics
            .iter()
            .map(|(slot, nic)| {
                let pcie_device_id = format!("mat_{slot}");
                redfish::pcie_device::builder_from_nic(
                    &redfish::pcie_device::chassis_resource(chassis_id, &pcie_device_id),
                    nic,
                )
                .status(redfish::resource::Status::Ok)
                .build()
            })
            .collect::<Vec<_>>();

        if self.gpu_profile == CiscoGpuProfile::MgxPcie {
            pcie_devices.push(
                redfish::pcie_device::builder(&redfish::pcie_device::chassis_resource(
                    chassis_id,
                    "mat_gpu_0",
                ))
                .manufacturer("NVIDIA")
                .model("H100 NVL")
                .status(redfish::resource::Status::Ok)
                .build(),
            );
        }

        let mut chassis = vec![redfish::chassis::SingleChassisConfig {
            id: chassis_id.into(),
            chassis_type: "RackMount".into(),
            manufacturer: Some("Cisco Systems Inc".into()),
            model: Some(self.product.to_string().into()),
            pcie_devices: Some(pcie_devices),
            ..redfish::chassis::SingleChassisConfig::defaults()
        }];

        if self.gpu_profile == CiscoGpuProfile::HgxSxm {
            chassis.push(redfish::chassis::SingleChassisConfig {
                id: "nvswitch".into(),
                chassis_type: "Component".into(),
                manufacturer: Some("NVIDIA".into()),
                model: Some("NVSwitch".into()),
                ..redfish::chassis::SingleChassisConfig::defaults()
            });

            for index in 0..8 {
                let gpu_chassis_id = format!("gpu_{index}");
                chassis.push(redfish::chassis::SingleChassisConfig {
                    id: gpu_chassis_id.clone().into(),
                    chassis_type: "Component".into(),
                    manufacturer: Some("NVIDIA".into()),
                    model: Some("H100 80GB HBM3".into()),
                    pcie_devices: Some(vec![
                        redfish::pcie_device::builder(&redfish::pcie_device::chassis_resource(
                            &gpu_chassis_id,
                            &format!("GPU_SXM_{index}"),
                        ))
                        .manufacturer("NVIDIA")
                        .model("H100 80GB HBM3")
                        .status(redfish::resource::Status::Ok)
                        .build(),
                    ]),
                    ..redfish::chassis::SingleChassisConfig::defaults()
                });
            }
        }

        redfish::chassis::ChassisConfig { chassis }
    }

    pub fn update_service_config(&self) -> redfish::update_service::UpdateServiceConfig {
        redfish::update_service::UpdateServiceConfig {
            firmware_inventory: vec![],
        }
    }

    pub fn discovery_info(&self) -> DiscoveryInfo {
        DiscoveryInfo {
            network_interfaces: self
                .nics
                .iter()
                .map(|(slot, nic)| nic.discovery_info(*slot))
                .collect(),
            machine_type: CpuArchitecture::X86_64.to_string(),
            machine_arch: Some(rpc::utils::cpu_architecture_to_rpc(CpuArchitecture::X86_64)),
            dmi_data: Some(DmiData {
                board_name: self.product.to_string(),
                board_version: "".into(),
                bios_version: "2.0(2.260062)".into(),
                bios_date: "01/01/2026".into(),
                product_serial: self.product_serial_number.to_string(),
                board_serial: self.product_serial_number.to_string(),
                chassis_serial: self.product_serial_number.to_string(),
                product_name: self.product.to_string(),
                sys_vendor: hw::bmc_vendor_to_udev_dmi(BMCVendor::Cisco).into(),
            }),
            ..Default::default()
        }
    }
}
