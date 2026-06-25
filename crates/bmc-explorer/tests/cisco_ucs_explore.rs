mod common;

use bmc_explorer::nv_generate_exploration_report;
use bmc_mock::{CiscoGpuProfile, test_support};
use bmc_vendor::BMCVendor;
use model::site_explorer::EndpointType;
use tokio::test;

async fn explore_cisco_ucs(product: &str, gpu_profile: CiscoGpuProfile) {
    let h = test_support::cisco_ucs_bmc(product, gpu_profile).await;
    let report = nv_generate_exploration_report(h.service_root, &common::explorer_config())
        .await
        .unwrap();

    assert_eq!(report.endpoint_type, EndpointType::Bmc);
    assert_eq!(report.vendor, Some(BMCVendor::Cisco));
    assert!(!report.systems.is_empty(), "systems must be present");
    assert!(!report.chassis.is_empty(), "chassis must be present");
    assert!(
        report
            .machine_setup_status
            .as_ref()
            .is_some_and(|status| status.is_done || !status.diffs.is_empty()),
        "machine setup status must be present and structurally valid"
    );
}

#[test]
async fn explore_cisco_ucs_c845a_m8_mgx_pcie() {
    explore_cisco_ucs("CAI-845A-M8", CiscoGpuProfile::MgxPcie).await;
}

#[test]
async fn explore_cisco_ucs_c885a_m8_hgx_sxm() {
    explore_cisco_ucs("CAI-885A-M8", CiscoGpuProfile::HgxSxm).await;
}
