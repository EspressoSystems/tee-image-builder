#!/usr/bin/env python3
"""
Chain Configuration Validator

This script validates chain configuration files against a set of rules.

Usage:
    python3 validate_config.py [chain_name_or_path]

    If no argument is provided, all JSON files under chain-configs/ are validated.

Examples:
    # Validate all config files
    python3 validate_config.py

    # Validate a specific chain by name
    python3 validate_config.py rari-testnet
    python3 validate_config.py apechain-testnet

    # Validate a specific file path
    python3 validate_config.py chain-configs/nitro/rari-testnet.json

Exit Codes:
    0 - Validation passed (may have warnings)
    1 - Validation failed (has errors)
"""

import json
import sys
from pathlib import Path
from typing import List, Tuple, Optional
from dataclasses import dataclass

PLACEHOLDER = 'PLACEHOLDER'


def _is_placeholder(value) -> bool:
    """Returns True if a value is still a placeholder (not a real secret)."""
    return isinstance(value, str) and value.strip() == PLACEHOLDER


@dataclass
class ValidationResult:
    """Represents the result of a validation check"""
    rule_name: str
    passed: bool
    message: str
    severity: str = "error"  # "error", "warning", "info"


class ConfigValidator:
    """Validates chain configuration files"""

    _exceptions = None

    def __init__(self, config_path: str):
        self.config_path = Path(config_path)
        self.config = None
        self.errors = []
        self.warnings = []
        self.info = []

    @classmethod
    def load_exceptions(cls):
        """Load validation exceptions from file"""
        if cls._exceptions is not None:
            return cls._exceptions

        exceptions_file = Path('validation_exceptions.json')
        if exceptions_file.exists():
            try:
                with open(exceptions_file, 'r') as f:
                    cls._exceptions = json.load(f)
            except Exception as e:
                print(f"Warning: Could not load exceptions file: {e}", file=sys.stderr)
                cls._exceptions = {}
        else:
            cls._exceptions = {}

        return cls._exceptions

    def is_file_exception(self, rule_name: str) -> bool:
        """Check if current file has an exception for a specific rule"""
        exceptions = self.load_exceptions()
        rule_exceptions = exceptions.get('rule_exceptions', {})

        if rule_name not in rule_exceptions:
            return False

        rule_config = rule_exceptions[rule_name]
        rel_path = str(self.config_path)

        if 'skip_validation' in rule_config:
            for file_pattern in rule_config['skip_validation'].get('files', []):
                if (file_pattern == rel_path or
                    file_pattern in rel_path or
                    rel_path.endswith(file_pattern)):
                    return True

        return False

    def load_config(self):
        """Load and parse the configuration file.
        Returns True on success, False on error, None if file is empty (skip)."""
        try:
            if not self.config_path.exists():
                print(f"Error: File not found: {self.config_path}")
                return False

            content = self.config_path.read_text().strip()
            if not content:
                return None  # Empty file — skip silently

            self.config = json.loads(content)
            return True
        except json.JSONDecodeError as e:
            print(f"Error: Invalid JSON in {self.config_path}: {e}")
            return False
        except Exception as e:
            print(f"Error loading {self.config_path}: {e}")
            return False

    def validate_all(self) -> Tuple[int, int, int]:
        """
        Run all validation rules

        TO ADD A NEW VALIDATION RULE:
        1. Create a new method like: def _validate_your_feature(self):
        2. Add it to the list below: self._validate_your_feature()
        3. Use self.errors.append() for critical issues (causes failure)
        4. Use self.warnings.append() for non-critical issues (best practices)
        5. Use self.info.append() for informational messages
        """
        if not self.config:
            print("Error: No configuration loaded")
            return 0, 0, 0

        self.errors = []
        self.warnings = []
        self.info = []

        self._validate_structure()
        self._validate_private_values()
        self._validate_espresso_batcher_config()
        self._validate_data_availability()

        return len(self.errors), len(self.warnings), len(self.info)

    def _validate_structure(self):
        """Rule: Validate basic configuration structure"""
        required_sections = ['chain', 'parent-chain', 'http', 'ws', 'node', 'execution', 'persistent']

        for section in required_sections:
            if section not in self.config:
                self.errors.append(ValidationResult(
                    rule_name="structure",
                    passed=False,
                    message=f"Missing required section: '{section}'"
                ))

        if 'persistent' in self.config:
            persistent_config = self.config['persistent']
            if 'chain' in persistent_config:
                chain = persistent_config['chain']
                exceptions = self.load_exceptions()
                allowed_values = exceptions.get('persistent_chain', {}).get('allowed_values', ['local'])

                if chain not in allowed_values:
                    self.errors.append(ValidationResult(
                        rule_name="persistent_chain",
                        passed=False,
                        message="Persistent chain must be set to `local` or one of the exceptions"
                    ))
            else:
                self.errors.append(ValidationResult(
                    rule_name="persistent_chain",
                    passed=False,
                    message="Persistent chain is not set"
                ))

    def _validate_private_values(self):
        """Rule: Validate that all private/secret values use the ADD_PRIVATE_KEY placeholder.

        Private values are credentials and secret service URLs that must not be committed.
        They must either remain as a '<PLACEHOLDER>' template string or use ADD_PRIVATE_KEY.
        """
        bp_config = self.config.get('node', {}).get('batch-poster', {})

        # Batch poster private key
        if 'parent-chain-wallet' in bp_config:
            private_key = bp_config['parent-chain-wallet'].get('private-key', '')
            if private_key != PLACEHOLDER:
                self.errors.append(ValidationResult(
                    rule_name="private_key",
                    passed=False,
                    message=f"Batch poster private key must be set to '{PLACEHOLDER}'"
                ))

        # Celestia URL (private service endpoint)
        celestia_cfg = self.config.get('node', {}).get('celestia-cfg', {})
        if celestia_cfg.get('enable') and 'url' in celestia_cfg:
            if not _is_placeholder(celestia_cfg['url']):
                self.errors.append(ValidationResult(
                    rule_name="celestia_url",
                    passed=False,
                    message="Celestia URL must remain as a placeholder — do not commit private service URLs"
                ))

    def _validate_espresso_batcher_config(self):
        """Rule: Validate Espresso Batch Poster configuration"""
        if 'node' not in self.config or 'batch-poster' not in self.config['node']:
            return

        bp_config = self.config['node']['batch-poster']

        if 'enable' in bp_config and not bp_config['enable']:
            self.errors.append(ValidationResult(
                rule_name="espresso_batcher_enable",
                passed=False,
                message="Batch poster is disabled, but it should be enabled"
            ))

        if 'hotshot-urls' in bp_config:
            urls = bp_config['hotshot-urls']
            if not isinstance(urls, list) or len(urls) == 0:
                self.errors.append(ValidationResult(
                    rule_name="espresso_hotshot_urls",
                    passed=False,
                    message="hotshot-urls must be a non-empty list"
                ))
            elif len(urls) < 3:
                self.warnings.append(ValidationResult(
                    rule_name="espresso_hotshot_urls",
                    passed=True,
                    message="Recommend at least 3 hotshot URLs for redundancy"
                ))
            elif len(urls) != len(set(urls)):
                duplicates = [url for url in set(urls) if urls.count(url) > 1]
                self.errors.append(ValidationResult(
                    rule_name="espresso_hotshot_urls",
                    passed=False,
                    message=f"Duplicate hotshot URLs found: {', '.join(duplicates)}"
                ))

        if 'espresso-tee-verifier-address' in bp_config:
            verifier = bp_config['espresso-tee-verifier-address']
            if not verifier.startswith('0x') or len(verifier) != 42:
                self.errors.append(ValidationResult(
                    rule_name="espresso_tee_verifier_address",
                    passed=False,
                    message="espresso-tee-verifier-address must be a valid Ethereum address"
                ))

        espresso_bp_config = self.config.get('node', {}).get('espresso', {}).get('batch-poster', {})

        if 'espresso-tee-type' in bp_config:
            tee_type = bp_config['espresso-tee-type']
            if tee_type not in ['NITRO', 'SGX']:
                self.errors.append(ValidationResult(
                    rule_name="espresso_tee_type",
                    passed=False,
                    message="espresso-tee-type must be either 'NITRO' or 'SGX'"
                ))
        elif 'tee-type' in espresso_bp_config:
            tee_type = espresso_bp_config['tee-type']
            if tee_type not in ['NITRO', 'SGX']:
                self.errors.append(ValidationResult(
                    rule_name="espresso_tee_type",
                    passed=False,
                    message="tee-type must be either 'NITRO' or 'SGX'"
                ))
        else:
            if not self.is_file_exception('espresso_tee_type'):
                self.errors.append(ValidationResult(
                    rule_name="espresso_tee_type",
                    passed=False,
                    message="espresso-tee-type or tee-type is not set"
                ))

    def _validate_data_availability(self):
        """Rule: Validate data availability configuration"""
        if 'node' not in self.config or 'data-availability' not in self.config['node']:
            return

        da_config = self.config['node']['data-availability']

        if 'enable' in da_config and not da_config['enable']:
            self.errors.append(ValidationResult(
                rule_name="data_availability_enable",
                passed=False,
                message="Data availability is disabled, but it should be enabled"
            ))

        if 'rest-aggregator' in da_config:
            rest_config = da_config['rest-aggregator']
            if 'enable' in rest_config and not rest_config['enable']:
                self.errors.append(ValidationResult(
                    rule_name="data_availability_rest_aggregator_enable",
                    passed=False,
                    message="REST aggregator is disabled, but it should be enabled"
                ))

            if 'urls' in rest_config:
                urls = rest_config['urls']
                url_list = [urls] if isinstance(urls, str) else (urls or [])
                if not url_list:
                    self.errors.append(ValidationResult(
                        rule_name="data_availability_rest_aggregator_urls",
                        passed=False,
                        message="REST aggregator URLs are not set"
                    ))
                elif not all(_is_placeholder(u) for u in url_list):
                    self.errors.append(ValidationResult(
                        rule_name="data_availability_rest_aggregator_urls",
                        passed=False,
                        message="REST aggregator URLs must remain as placeholders — do not commit private service URLs"
                    ))

        if 'rpc-aggregator' in da_config:
            rpc_config = da_config['rpc-aggregator']
            if 'enable' in rpc_config and not rpc_config['enable']:
                self.errors.append(ValidationResult(
                    rule_name="data_availability_rpc_aggregator_enable",
                    passed=False,
                    message="RPC aggregator is disabled, but it should be enabled"
                ))

            backends = rpc_config.get('backends', '')
            if not backends:
                self.errors.append(ValidationResult(
                    rule_name="data_availability_rpc_aggregator_backends",
                    passed=False,
                    message="RPC aggregator backends are not set"
                ))
            elif not _is_placeholder(backends):
                self.errors.append(ValidationResult(
                    rule_name="data_availability_rpc_aggregator_backends",
                    passed=False,
                    message="RPC aggregator backends must remain as a placeholder — do not commit private service URLs"
                ))

    def has_issues(self) -> bool:
        """Check if there are any errors or warnings"""
        return len(self.errors) > 0 or len(self.warnings) > 0

    def print_results(self) -> bool:
        """Print validation results. Returns success (True if no errors)"""
        if not self.has_issues():
            return True

        if self.errors:
            print(f"\n❌ Errors ({len(self.errors)}):")
            for result in self.errors:
                print(f"   • {result.message}")

        if self.warnings:
            print(f"\n⚠️  Warnings ({len(self.warnings)}):")
            for result in self.warnings:
                print(f"   • {result.message}")

        return len(self.errors) == 0


def find_config_files(arg: Optional[str] = None) -> List[Path]:
    """Find chain config files to validate"""
    if arg:
        # Direct file path
        path = Path(arg)
        if path.exists() and path.is_file():
            return [path]

        # Chain name lookup (e.g. "rari-testnet" → chain-configs/nitro/rari-testnet.json)
        if Path('chain-configs').exists():
            matches = list(Path('chain-configs').rglob(f'{arg}.json'))
            if matches:
                return matches

        # Glob pattern fallback
        return list(Path('.').rglob(arg))

    # Default: all JSON files under chain-configs/
    if Path('chain-configs').exists():
        return list(Path('chain-configs').rglob('*.json'))
    return []


def main():
    """Main entry point"""
    arg = sys.argv[1] if len(sys.argv) >= 2 else None
    config_files = find_config_files(arg)

    if not config_files:
        if arg:
            print(f"Error: No config files found for: {arg}")
        else:
            print("Error: No config files found under chain-configs/")
        sys.exit(1)

    if len(config_files) > 1:
        print(f"Found {len(config_files)} config file(s) to validate\n")

    total_errors = 0
    total_warnings = 0
    all_success = True

    for config_path in sorted(config_files):
        validator = ConfigValidator(str(config_path))
        result = validator.load_config()
        if result is None:
            continue  # Empty file — skip silently
        if result is False:
            all_success = False
            total_errors += 1
            continue

        errors, warnings, info = validator.validate_all()
        total_errors += errors
        total_warnings += warnings

        if validator.has_issues():
            print(f"\n📄 {config_path}")
            print("-" * len(str(config_path)))
            success = validator.print_results()
            if not success:
                all_success = False
        elif len(config_files) == 1:
            print(f"✓ {config_path} - No issues found")

    if len(config_files) > 1:
        print(f"\n{'─' * 70}")
        if total_errors > 0 or total_warnings > 0:
            print(f"Summary: {len(config_files)} file(s) validated")
            print(f"  ❌ {total_errors} error(s)")
            print(f"  ⚠️  {total_warnings} warning(s)")
        else:
            print(f"✓ All {len(config_files)} file(s) validated successfully")

    sys.exit(0 if all_success and total_errors == 0 else 1)


if __name__ == "__main__":
    main()
