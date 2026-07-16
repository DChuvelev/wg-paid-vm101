#!/bin/sh
# Provider cache/log retention only. No production-slot state is owned here.
find /root/hmn/backups -type f -name 'network-before-vpn_test-*' -mtime +7 -exec rm -f {} \; 2>/dev/null || true
find /root/hmn/test-runs -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf {} \; 2>/dev/null || true
find /root/hmn/runs -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf {} \; 2>/dev/null || true
find /root/hmn/cache -type f -name '*.before-*' -mtime +14 -exec rm -f {} \; 2>/dev/null || true
exit 0
