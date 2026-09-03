#!/usr/bin/ksh

# AIX Infrastructure Reliability Health Check
# Author: Tanaka Kambasha
# Version: 1.0

separator()
{
    echo ""
    echo "============================================================"
    echo " $1"
    echo "============================================================"
}

echo "============================================================"
echo " AIX INFRASTRUCTURE RELIABILITY HEALTH CHECK"
echo "============================================================"

echo ""
echo "Generated:"
date

separator "SYSTEM INFORMATION"

echo "Hostname:"
hostname

echo ""
echo "AIX Level:"
oslevel -s

echo ""
echo "System Uptime:"
uptime


separator "LPAR INFORMATION"

if command -v lparstat >/dev/null 2>&1
then
    lparstat -i
else
    echo "lparstat not available"
fi


separator "MEMORY AND PAGING"

echo "Paging Space:"
lsps -a

echo ""
echo "Memory Summary:"
svmon -G


separator "FILESYSTEMS"

df -g


separator "VOLUME GROUPS"

echo "All Volume Groups:"
lsvg

echo ""
echo "Active Volume Groups:"
lsvg -o


separator "PHYSICAL VOLUMES"

lspv


separator "STORAGE PATHS"

lspath


separator "AIX ERROR REPORT"

errpt


separator "NETWORK"

echo "Interfaces:"
ifconfig -a

echo ""
echo "Routing Table:"
netstat -rn


separator "POWERHA"

if command -v clstat >/dev/null 2>&1
then
    clstat
else
    echo "PowerHA clstat command not available"
fi


separator "HEALTH CHECK COMPLETE"

echo "Collection completed successfully."