#!/bin/sh

find /root/hmn/backups -type f -name 'network-before-vpn_test-*' -mtime +7 -exec rm -f {} \; 2>/dev/null

find /root/hmn/logs -type f \( \
  -name 'validate-current-pool-*.log' -o \
  -name 'refresh-pool-safe-*.log' -o \
  -name 'hmn-refresh-awg-*.report.txt' -o \
  -name 'hmn-refresh-awg-*.log' \
\) -mtime +14 -exec rm -f {} \; 2>/dev/null

find /root/hmn/cache -type f -name '*.before-*' -mtime +14 -exec rm -f {} \; 2>/dev/null
find /root/hmn/state -type f -name '*.before-*' -mtime +14 -exec rm -f {} \; 2>/dev/null

exit 0
