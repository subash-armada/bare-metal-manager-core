/*
 * SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
 * SPDX-License-Identifier: MIT
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

//! Cisco UCS (AMI MegaRAC) helpers. The live `Redfish` implementation reuses
//! [`crate::ami::Bmc`] with `RedfishVendor::Cisco` and branches on vendor there.

use std::collections::HashMap;

use serde_json::Value;

use crate::model::boot::{AutomaticRetryConfig, Boot};

/// Cisco UCS uses Redfish `Boot.AutomaticRetryConfig`, not AMI `EndlessBoot` BIOS attr.
pub fn is_automatic_retry_boot_enabled(boot: &Boot) -> bool {
    boot.automatic_retry_config == Some(AutomaticRetryConfig::RetryAttempts)
        && boot.automatic_retry_attempts.unwrap_or(0) > 0
}

/// BIOS attributes applied during machine setup on Cisco UCS platforms.
pub fn machine_setup_attrs() -> HashMap<String, Value> {
    HashMap::from([
        ("NWSK000".to_string(), "Enabled".into()),
        ("NWSK001".to_string(), "Enabled".into()),
        ("NWSK006".to_string(), "Enabled".into()),
        ("NWSK002".to_string(), "Disabled".into()),
        ("NWSK007".to_string(), "Disabled".into()),
    ])
}

/// Serial console BIOS attributes for Cisco UCS (TER* layout differs from generic AMI).
pub fn serial_console_attrs() -> HashMap<String, Value> {
    HashMap::from([
        ("TER001".to_string(), "Enabled".into()),
        ("TER010".to_string(), "Enabled".into()),
        ("TER06B".to_string(), "COM0".into()),
        ("TER0021".to_string(), "115200".into()),
        ("TER0020".to_string(), "115200".into()),
        ("TER012".to_string(), "ANSI".into()),
        ("TER011".to_string(), "VT-UTF8".into()),
        ("TER05D".to_string(), "None".into()),
    ])
}

/// Expected serial-console attribute checks for `serial_console_status`.
pub fn serial_console_expected() -> &'static [(&'static str, &'static str, &'static str)] {
    &[
        ("TER001", "Enabled", "Disabled"),
        ("TER010", "Enabled", "Disabled"),
        ("TER06B", "COM0", "any"),
        ("TER0021", "115200", "any"),
        ("TER0020", "115200", "any"),
        ("TER012", "ANSI", "any"),
        ("TER011", "VT-UTF8", "any"),
        ("TER05D", "None", "any"),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn automatic_retry_boot_enabled_when_configured() {
        let boot = Boot {
            automatic_retry_config: Some(AutomaticRetryConfig::RetryAttempts),
            automatic_retry_attempts: Some(999),
            ..Default::default()
        };
        assert!(is_automatic_retry_boot_enabled(&boot));
    }

    #[test]
    fn automatic_retry_boot_disabled_without_attempts() {
        let boot = Boot {
            automatic_retry_config: Some(AutomaticRetryConfig::RetryAttempts),
            automatic_retry_attempts: Some(0),
            ..Default::default()
        };
        assert!(!is_automatic_retry_boot_enabled(&boot));
    }

    #[test]
    fn automatic_retry_boot_disabled_when_not_retry_attempts_mode() {
        let boot = Boot {
            automatic_retry_config: Some(AutomaticRetryConfig::Disabled),
            automatic_retry_attempts: Some(999),
            ..Default::default()
        };
        assert!(!is_automatic_retry_boot_enabled(&boot));
    }
}
