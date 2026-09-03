#!/usr/bin/ksh

###############################################################################
# AIX Infrastructure Reliability Health Check
# Version: 2.0
#
# Purpose
#   Read-only AIX health assessment for pre-change/post-change validation.
#   Supports real AIX execution and deterministic mock profiles for development.
#
# Exit codes
#   0 = OK
#   1 = WARNING
#   2 = CRITICAL
#   3 = UNKNOWN / unsupported execution mode
#
# Examples
#   Real AIX:
#     ./scripts/aix_healthcheck.sh
#
#   Mock tests:
#     MOCK_MODE=1 MOCK_PROFILE=healthy bash scripts/aix_healthcheck.sh
#     MOCK_MODE=1 MOCK_PROFILE=degraded bash scripts/aix_healthcheck.sh
#
#   Pre/post labels:
#     CHECK_TYPE=precheck ./scripts/aix_healthcheck.sh
#     CHECK_TYPE=postcheck ./scripts/aix_healthcheck.sh
###############################################################################

###############################################################################
# CONFIGURATION
###############################################################################

MOCK_MODE="${MOCK_MODE:-0}"
MOCK_PROFILE="${MOCK_PROFILE:-healthy}"
CHECK_TYPE="${CHECK_TYPE:-healthcheck}"

# Capacity thresholds
FS_WARN="${FS_WARN:-80}"
FS_CRIT="${FS_CRIT:-90}"
INODE_WARN="${INODE_WARN:-80}"
INODE_CRIT="${INODE_CRIT:-90}"
PAGING_WARN="${PAGING_WARN:-70}"
PAGING_CRIT="${PAGING_CRIT:-85}"

# Performance thresholds
CPU_WARN="${CPU_WARN:-85}"
CPU_CRIT="${CPU_CRIT:-95}"
IOWAIT_WARN="${IOWAIT_WARN:-15}"
IOWAIT_CRIT="${IOWAIT_CRIT:-30}"
RUNQ_PER_CPU_WARN="${RUNQ_PER_CPU_WARN:-1.5}"
RUNQ_PER_CPU_CRIT="${RUNQ_PER_CPU_CRIT:-2.0}"
PAGEOUT_WARN="${PAGEOUT_WARN:-5}"
PAGEOUT_CRIT="${PAGEOUT_CRIT:-20}"
DISK_BUSY_WARN="${DISK_BUSY_WARN:-80}"
DISK_BUSY_CRIT="${DISK_BUSY_CRIT:-95}"

PERF_INTERVAL="${PERF_INTERVAL:-2}"
PERF_COUNT="${PERF_COUNT:-3}"

# Environment expectations. Space-separated values.
EXPECTED_MOUNTS="${EXPECTED_MOUNTS:-/ /usr /var /tmp}"
EXPECTED_ACTIVE_VGS="${EXPECTED_ACTIVE_VGS:-}"
CRITICAL_SUBSYSTEMS="${CRITICAL_SUBSYSTEMS:-sshd}"
REQUIRED_ADAPTERS="${REQUIRED_ADAPTERS:-}"

# Optional checks
REQUIRE_NTP="${REQUIRE_NTP:-0}"
NTP_SUBSYSTEM="${NTP_SUBSYSTEM:-xntpd}"
POWERHA_REQUIRED="${POWERHA_REQUIRED:-0}"
PING_GATEWAY="${PING_GATEWAY:-0}"
DNS_TEST_HOST="${DNS_TEST_HOST:-}"
COLLECT_FCSTAT="${COLLECT_FCSTAT:-0}"
COLLECT_ENTSTAT="${COLLECT_ENTSTAT:-0}"

# errpt scope. AIX format: mmddhhmmyy, for example 0903000026.
# If unset, the full error log is collected, but historical permanent hardware
# errors are downgraded to WARNING to avoid failing a change on stale history.
ERRPT_START="${ERRPT_START:-}"
ERRPT_ENFORCE_ALL="${ERRPT_ENFORCE_ALL:-0}"

###############################################################################
# STATUS VALUES
###############################################################################

OVERALL_STATUS=0
OS_STATUS=0
PERF_STATUS=0
PAGING_STATUS=0
FS_STATUS=0
VG_STATUS=0
PV_STATUS=0
MPIO_STATUS=0
DEVICE_STATUS=0
IO_STATUS=0
ERRPT_STATUS=0
NETWORK_STATUS=0
SERVICE_STATUS=0
NTP_STATUS=0
DUMP_STATUS=0
POWERHA_STATUS=0

# Captured metrics for the summary file
METRIC_VCPU=""
METRIC_RUNQ=""
METRIC_CPU_BUSY=""
METRIC_IOWAIT=""
METRIC_PAGEIN=""
METRIC_PAGEOUT=""
METRIC_PAGING_PERCENT=""
METRIC_MAX_DISK_BUSY=""
METRIC_FAILED_PATHS=""
METRIC_FAILED_UNITS=""
POWERHA_STATE="N/A"

###############################################################################
# PROJECT PATHS
###############################################################################

SCRIPT_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
REPORT_DIR="${PROJECT_DIR}/reports"

if [ "$MOCK_MODE" -eq 1 ] 2>/dev/null; then
    HOST_SHORT="mock-${MOCK_PROFILE}"
else
    HOST_SHORT=$(hostname 2>/dev/null | cut -d. -f1)
fi

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
REPORT_FILE="${REPORT_DIR}/${HOST_SHORT}_${TIMESTAMP}_${CHECK_TYPE}.txt"
SUMMARY_FILE="${REPORT_DIR}/${HOST_SHORT}_${TIMESTAMP}_${CHECK_TYPE}.summary"
TMP_BASE="/tmp/aix_healthcheck.$$"

mkdir -p "$REPORT_DIR" || exit 3
trap 'rm -f ${TMP_BASE}.* 2>/dev/null' 0 1 2 15

###############################################################################
# UTILITY FUNCTIONS
###############################################################################

separator()
{
    echo ""
    echo "======================================================================"
    echo " $1"
    echo "======================================================================"
}

status_name()
{
    case "$1" in
        0) echo "OK" ;;
        1) echo "WARNING" ;;
        2) echo "CRITICAL" ;;
        *) echo "UNKNOWN" ;;
    esac
}

set_overall_status()
{
    new_status="$1"
    if [ "$new_status" -gt "$OVERALL_STATUS" ] 2>/dev/null; then
        OVERALL_STATUS="$new_status"
    fi
}

command_exists()
{
    command -v "$1" >/dev/null 2>&1
}

is_number()
{
    echo "$1" | awk 'BEGIN{ok=0} /^[0-9]+([.][0-9]+)?$/ {ok=1} END{exit ok?0:1}'
}

float_ge()
{
    awk -v a="$1" -v b="$2" 'BEGIN { exit (a+0 >= b+0) ? 0 : 1 }'
}

trim()
{
    echo "$1" | awk '{$1=$1; print}'
}

###############################################################################
# MOCK / REAL COLLECTORS
###############################################################################

collect_oslevel()
{
    if [ "$MOCK_MODE" -eq 1 ]; then
        echo "7200-05-11-2546"
    else
        oslevel -s
    fi
}

collect_uptime()
{
    if [ "$MOCK_MODE" -eq 1 ]; then
        echo "12:14PM up 64 days, 4:32, 3 users, load average: 0.45, 0.38, 0.31"
    else
        uptime
    fi
}

collect_lparstat_info()
{
    if [ "$MOCK_MODE" -eq 1 ]; then
        cat <<'MOCK'
Node Name                                  : aixdb01
Partition Name                             : PROD_DB01
Partition Number                           : 4
Type                                       : Shared-SMT-8
Mode                                       : Uncapped
Entitled Capacity                          : 2.00
Online Virtual CPUs                        : 4
Maximum Virtual CPUs                       : 8
Online Memory                              : 32768 MB
Maximum Memory                             : 65536 MB
MOCK
    elif command_exists lparstat; then
        lparstat -i
    else
        echo "lparstat command unavailable"
        return 1
    fi
}

collect_vmstat()
{
    if [ "$MOCK_MODE" -eq 1 ]; then
        if [ "$MOCK_PROFILE" = "degraded" ]; then
            cat <<'MOCK'
System configuration: lcpu=4 mem=32768MB
kthr     memory             page              faults        cpu
----- ----------- ------------------------ ------------ -----------
 r  b   avm   fre  re  pi  po  fr   sr  cy  in   sy  cs us sy id wa
 2  0 800000 200000   0   0   0   0    0   0 100 1000 400 25 10 55 10
 7  1 810000 180000   0   5  12  20   50   0 150 5000 900 70 18  5  7
 9  2 820000 160000   0   8  15  25   60   0 180 6500 1100 72 20  3  5
MOCK
        else
            cat <<'MOCK'
System configuration: lcpu=4 mem=32768MB
kthr     memory             page              faults        cpu
----- ----------- ------------------------ ------------ -----------
 r  b   avm   fre  re  pi  po  fr   sr  cy  in   sy  cs us sy id wa
 1  0 500000 300000   0   0   0   0    0   0 100 1000 400 10  5 84  1
 1  0 500100 299900   0   0   0   0    0   0 105 1050 410 12  5 82  1
 0  0 500200 299800   0   0   0   0    0   0 102 1010 405 11  4 84  1
MOCK
        fi
    else
        vmstat "$PERF_INTERVAL" "$PERF_COUNT"
    fi
}

collect_iostat()
{
    if [ "$MOCK_MODE" -eq 1 ]; then
        if [ "$MOCK_PROFILE" = "degraded" ]; then
            cat <<'MOCK'
tty:      tin         tout   avg-cpu:  % user    % sys     % idle    % iowait
          0.0          0.0              40.0     20.0       20.0      20.0
Disks:        % tm_act     Kbps      tps    Kb_read   Kb_wrtn
hdisk0           25.0     100.0     10.0       1000       1000
hdisk2           96.0    2500.0    400.0      20000      30000
hdisk3           88.0    2100.0    350.0      18000      25000
MOCK
        else
            cat <<'MOCK'
tty:      tin         tout   avg-cpu:  % user    % sys     % idle    % iowait
          0.0          0.0              10.0      5.0       84.0       1.0
Disks:        % tm_act     Kbps      tps    Kb_read   Kb_wrtn
hdisk0            5.0      20.0      2.0        100         50
hdisk2           22.0     400.0     40.0       3000       2000
hdisk3           18.0     350.0     35.0       2500       1800
MOCK
        fi
    else
        iostat "$PERF_INTERVAL" 2
    fi
}

collect_lsps_summary()
{
    if [ "$MOCK_MODE" -eq 1 ]; then
        if [ "$MOCK_PROFILE" = "degraded" ]; then
            echo "Total Paging Space   Percent Used"
            echo "      8192MB              88%"
        else
            echo "Total Paging Space   Percent Used"
            echo "      8192MB               3%"
        fi
    else
        lsps -s
    fi
}

collect_lsps_detail()
{
    if [ "$MOCK_MODE" -eq 1 ]; then
        if [ "$MOCK_PROFILE" = "degraded" ]; then
            cat <<'MOCK'
Page Space      Physical Volume   Volume Group    Size %Used Active Auto Type Chksum
hd6             hdisk0            rootvg        4096MB    92   yes   yes    lv     0
paging00        hdisk1            rootvg        4096MB    84   yes   yes    lv     0
MOCK
        else
            cat <<'MOCK'
Page Space      Physical Volume   Volume Group    Size %Used Active Auto Type Chksum
hd6             hdisk0            rootvg        4096MB     3   yes   yes    lv     0
paging00        hdisk1            rootvg        4096MB     2   yes   yes    lv     0
MOCK
        fi
    else
        lsps -a
    fi
}

collect_svmon()
{
    if [ "$MOCK_MODE" -eq 1 ]; then
        cat <<'MOCK'
               size       inuse        free         pin     virtual   available
memory      8388608     5421136     2967472     621443     3921102     2819021
pg space    2097152      103441

               work        pers        clnt       other
pin          521443           0           0      100000
in use      4211021           0     1210115
MOCK
    else
        svmon -G
    fi
}

collect_df()
{
    if [ "$MOCK_MODE" -eq 1 ]; then
        if [ "$MOCK_PROFILE" = "degraded" ]; then
            cat <<'MOCK'
Filesystem    GB blocks      Free %Used    Iused %Iused Mounted on
/dev/hd4           5.00      4.10   18%    12000     3% /
/dev/hd2          10.00      6.20   38%    45000     8% /usr
/dev/hd9var        5.00      0.70   86%     2500    83% /var
/dev/hd3          10.00      7.90   21%     1800     1% /tmp
/dev/oraclelv    200.00     12.00   94%   450000    22% /oracle
MOCK
        else
            cat <<'MOCK'
Filesystem    GB blocks      Free %Used    Iused %Iused Mounted on
/dev/hd4           5.00      4.10   18%    12000     3% /
/dev/hd2          10.00      6.20   38%    45000     8% /usr
/dev/hd9var        5.00      3.75   25%     2500     2% /var
/dev/hd3          10.00      7.90   21%     1800     1% /tmp
/dev/oraclelv    200.00     90.00   55%   450000    22% /oracle
MOCK
        fi
    else
        df -g
    fi
}

collect_lsvg()
{
    if [ "$MOCK_MODE" -eq 1 ]; then
        printf '%s\n' rootvg datavg oraclevg
    else
        lsvg
    fi
}

collect_lsvg_active()
{
    if [ "$MOCK_MODE" -eq 1 ]; then
        printf '%s\n' rootvg datavg oraclevg
    else
        lsvg -o
    fi
}

collect_lsvg_detail()
{
    vg="$1"
    if [ "$MOCK_MODE" -eq 1 ]; then
        if [ "$MOCK_PROFILE" = "degraded" ] && [ "$vg" = "datavg" ]; then
            cat <<MOCK
VOLUME GROUP:       $vg                    VG IDENTIFIER:  00f9mock00000001
VG STATE:           active                 PP SIZE:        256 megabyte(s)
VG PERMISSION:      read/write             TOTAL PPs:      800
MAX LVs:            256                    FREE PPs:       5
LVs:                6                      USED PPs:       795
OPEN LVs:           6                      QUORUM:         2 (Enabled)
TOTAL PVs:          2                      VG DESCRIPTORS: 3
STALE PVs:          1                      STALE PPs:      12
ACTIVE PVs:         2                      AUTO ON:        yes
MOCK
        else
            cat <<MOCK
VOLUME GROUP:       $vg                    VG IDENTIFIER:  00f9mock00000001
VG STATE:           active                 PP SIZE:        256 megabyte(s)
VG PERMISSION:      read/write             TOTAL PPs:      800
MAX LVs:            256                    FREE PPs:       120
LVs:                6                      USED PPs:       680
OPEN LVs:           6                      QUORUM:         2 (Enabled)
TOTAL PVs:          2                      VG DESCRIPTORS: 3
STALE PVs:          0                      STALE PPs:      0
ACTIVE PVs:         2                      AUTO ON:        yes
MOCK
        fi
    else
        lsvg "$vg"
    fi
}

collect_lsvg_lvs()
{
    vg="$1"
    if [ "$MOCK_MODE" -eq 1 ]; then
        if [ "$MOCK_PROFILE" = "degraded" ] && [ "$vg" = "datavg" ]; then
            cat <<'MOCK'
datavg:
LV NAME             TYPE       LPs     PPs     PVs  LV STATE      MOUNT POINT
datalv              jfs2       100     200     2    open/stale    /data
loglv                jfs2log    1       1       1    open/syncd    N/A
MOCK
        else
            cat <<MOCK
$vg:
LV NAME             TYPE       LPs     PPs     PVs  LV STATE      MOUNT POINT
${vg}lv              jfs2       100     100     2    open/syncd    /${vg}
MOCK
        fi
    else
        lsvg -l "$vg"
    fi
}

collect_lspv()
{
    if [ "$MOCK_MODE" -eq 1 ]; then
        if [ "$MOCK_PROFILE" = "degraded" ]; then
            cat <<'MOCK'
hdisk0          00f9c87a12345678                    rootvg          active
hdisk1          00f9c87a12345679                    rootvg          active
hdisk2          00f9c87a12345680                    datavg          active
hdisk3          00f9c87a12345681                    datavg          missing
hdisk4          00f9c87a12345682                    oraclevg        active
hdisk5          00f9c87a12345683                    None
MOCK
        else
            cat <<'MOCK'
hdisk0          00f9c87a12345678                    rootvg          active
hdisk1          00f9c87a12345679                    rootvg          active
hdisk2          00f9c87a12345680                    datavg          active
hdisk3          00f9c87a12345681                    datavg          active
hdisk4          00f9c87a12345682                    oraclevg        active
hdisk5          00f9c87a12345683                    None
MOCK
        fi
    else
        lspv
    fi
}

collect_lspath()
{
    if [ "$MOCK_MODE" -eq 1 ]; then
        if [ "$MOCK_PROFILE" = "degraded" ]; then
            cat <<'MOCK'
Enabled hdisk0 fscsi0
Enabled hdisk0 fscsi1
Enabled hdisk1 fscsi0
Enabled hdisk1 fscsi1
Enabled hdisk2 fscsi0
Enabled hdisk2 fscsi1
Failed  hdisk3 fscsi0
Failed  hdisk3 fscsi1
Enabled hdisk4 fscsi0
Failed  hdisk4 fscsi1
MOCK
        else
            cat <<'MOCK'
Enabled hdisk0 fscsi0
Enabled hdisk0 fscsi1
Enabled hdisk1 fscsi0
Enabled hdisk1 fscsi1
Enabled hdisk2 fscsi0
Enabled hdisk2 fscsi1
Enabled hdisk3 fscsi0
Enabled hdisk3 fscsi1
Enabled hdisk4 fscsi0
Enabled hdisk4 fscsi1
MOCK
        fi
    else
        lspath
    fi
}

collect_lsdev_disks()
{
    if [ "$MOCK_MODE" -eq 1 ]; then
        if [ "$MOCK_PROFILE" = "degraded" ]; then
            cat <<'MOCK'
hdisk0 Available 00-00-00 MPIO IBM 2076 FC Disk
hdisk1 Available 00-00-01 MPIO IBM 2076 FC Disk
hdisk2 Available 00-00-02 MPIO IBM 2076 FC Disk
hdisk3 Defined   00-00-03 MPIO IBM 2076 FC Disk
hdisk4 Available 00-00-04 MPIO IBM 2076 FC Disk
hdisk5 Available 00-00-05 MPIO IBM 2076 FC Disk
MOCK
        else
            cat <<'MOCK'
hdisk0 Available 00-00-00 MPIO IBM 2076 FC Disk
hdisk1 Available 00-00-01 MPIO IBM 2076 FC Disk
hdisk2 Available 00-00-02 MPIO IBM 2076 FC Disk
hdisk3 Available 00-00-03 MPIO IBM 2076 FC Disk
hdisk4 Available 00-00-04 MPIO IBM 2076 FC Disk
hdisk5 Available 00-00-05 MPIO IBM 2076 FC Disk
MOCK
        fi
    else
        lsdev -Cc disk
    fi
}

collect_lsdev_adapters()
{
    if [ "$MOCK_MODE" -eq 1 ]; then
        if [ "$MOCK_PROFILE" = "degraded" ]; then
            cat <<'MOCK'
fcs0 Available  C4-T1 Virtual Fibre Channel Client Adapter
fcs1 Defined    C5-T1 Virtual Fibre Channel Client Adapter
fscsi0 Available  Virtual SCSI Protocol Device
fscsi1 Available  Virtual SCSI Protocol Device
ent0 Available  Virtual I/O Ethernet Adapter
MOCK
        else
            cat <<'MOCK'
fcs0 Available  C4-T1 Virtual Fibre Channel Client Adapter
fcs1 Available  C5-T1 Virtual Fibre Channel Client Adapter
fscsi0 Available  Virtual SCSI Protocol Device
fscsi1 Available  Virtual SCSI Protocol Device
ent0 Available  Virtual I/O Ethernet Adapter
MOCK
        fi
    else
        lsdev -Cc adapter
    fi
}

collect_fcstat()
{
    adapter="$1"
    if [ "$MOCK_MODE" -eq 1 ]; then
        cat <<MOCK
FIBRE CHANNEL STATISTICS REPORT: $adapter
Device Type: Virtual Fibre Channel Client Adapter
Input Requests: 100000
Output Requests: 90000
Link Failure Count: 0
Loss of Sync Count: 0
Loss of Signal: 0
Invalid CRC Count: 0
MOCK
    else
        fcstat "$adapter"
    fi
}

collect_errpt()
{
    if [ "$MOCK_MODE" -eq 1 ]; then
        if [ "$MOCK_PROFILE" = "degraded" ]; then
            cat <<'MOCK'
IDENTIFIER TIMESTAMP  T C RESOURCE_NAME  DESCRIPTION
2BFA76F6   0903111026 P H hdisk3         DISK OPERATION ERROR
F7FA22C9   0903110526 P H fscsi0         ADAPTER ERROR
A6DF45AA   0903103026 T S inet0          INFORMATIONAL NETWORK EVENT
MOCK
        else
            cat <<'MOCK'
IDENTIFIER TIMESTAMP  T C RESOURCE_NAME  DESCRIPTION
A6DF45AA   0903103026 T S inet0          INFORMATIONAL NETWORK EVENT
MOCK
        fi
    else
        if [ -n "$ERRPT_START" ]; then
            errpt -s "$ERRPT_START"
        else
            errpt
        fi
    fi
}

collect_ifconfig()
{
    if [ "$MOCK_MODE" -eq 1 ]; then
        cat <<'MOCK'
en0: flags=1e084863,480<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST,GROUPRT>
        inet 10.20.30.40 netmask 0xffffff00 broadcast 10.20.30.255
lo0: flags=e08084b,c0<UP,BROADCAST,LOOPBACK,RUNNING,SIMPLEX,MULTICAST>
        inet 127.0.0.1 netmask 0xff000000
MOCK
    else
        ifconfig -a
    fi
}

collect_routes()
{
    if [ "$MOCK_MODE" -eq 1 ]; then
        cat <<'MOCK'
Routing tables
Destination        Gateway           Flags   Refs     Use  If   Exp  Groups
default            10.20.30.1        UG        8   12345  en0
10.20.30/24         10.20.30.40       U         1    2000  en0
127/8               127.0.0.1         U         4    5000  lo0
MOCK
    else
        netstat -rn
    fi
}

collect_lssrc()
{
    subsystem="$1"
    if [ "$MOCK_MODE" -eq 1 ]; then
        if [ "$MOCK_PROFILE" = "degraded" ] && [ "$subsystem" = "sshd" ]; then
            echo "Subsystem         Group            PID          Status"
            echo " $subsystem        ssh                           inoperative"
        else
            echo "Subsystem         Group            PID          Status"
            echo " $subsystem        system           12345        active"
        fi
    else
        lssrc -s "$subsystem"
    fi
}

collect_sysdumpdev()
{
    if [ "$MOCK_MODE" -eq 1 ]; then
        if [ "$MOCK_PROFILE" = "degraded" ]; then
            cat <<'MOCK'
primary              /dev/sysdumpnull
secondary            /dev/sysdumpnull
copy directory       /var/adm/ras
forced copy flag     TRUE
always allow dump    FALSE
MOCK
        else
            cat <<'MOCK'
primary              /dev/hd6
secondary            /dev/sysdumpnull
copy directory       /var/adm/ras
forced copy flag     TRUE
always allow dump    FALSE
MOCK
        fi
    else
        sysdumpdev -l
    fi
}

collect_lppchk()
{
    if [ "$MOCK_MODE" -eq 1 ]; then
        if [ "$MOCK_PROFILE" = "degraded" ]; then
            echo "0504-208 lppchk: fileset consistency problem detected"
            return 1
        fi
        return 0
    else
        lppchk -v
    fi
}

collect_powerha_state()
{
    if [ "$MOCK_MODE" -eq 1 ]; then
        if [ "$MOCK_PROFILE" = "degraded" ]; then
            echo "ERROR"
        else
            echo "STABLE"
        fi
    elif command_exists clmgr; then
        clmgr -cSa STATE query cluster 2>/dev/null
    else
        return 1
    fi
}

collect_powerha_detail()
{
    if [ "$MOCK_MODE" -eq 1 ]; then
        if [ "$MOCK_PROFILE" = "degraded" ]; then
            cat <<'MOCK'
PowerHA Version: 7.2.8
Cluster Name: PROD_CLUSTER
Cluster State: ERROR
Node aixdb01: UP
Node aixdb02: DOWN
Resource Group DB_RG: ERROR
MOCK
        else
            cat <<'MOCK'
PowerHA Version: 7.2.8
Cluster Name: PROD_CLUSTER
Cluster State: STABLE
Node aixdb01: UP
Node aixdb02: UP
Resource Group DB_RG: ONLINE
MOCK
        fi
    else
        if command_exists halevel; then
            echo "PowerHA Level:"
            halevel -s
            echo ""
        fi
        if command_exists clmgr; then
            echo "Cluster:"
            clmgr query cluster
            echo ""
            echo "Nodes:"
            clmgr query node
            echo ""
            echo "Resource Groups:"
            clmgr query resource_group
        else
            echo "PowerHA tools not detected"
        fi
    fi
}

###############################################################################
# HEALTH CHECKS
###############################################################################

check_os_integrity()
{
    separator "AIX SOFTWARE INTEGRITY"
    echo "AIX Level: $(collect_oslevel)"
    echo ""
    echo "lppchk -v:"

    LPP_FILE="${TMP_BASE}.lppchk"
    collect_lppchk > "$LPP_FILE" 2>&1
    rc=$?
    cat "$LPP_FILE"

    if [ "$rc" -eq 0 ]; then
        [ -s "$LPP_FILE" ] || echo "No inconsistencies reported"
        echo "Software Integrity: OK"
        OS_STATUS=0
    else
        echo "Software Integrity: CRITICAL - lppchk reported inconsistencies"
        OS_STATUS=2
        set_overall_status 2
    fi
}

check_performance()
{
    separator "CPU / MEMORY PRESSURE"

    VM_FILE="${TMP_BASE}.vmstat"
    LPAR_FILE="${TMP_BASE}.lparstat"
    collect_vmstat > "$VM_FILE" 2>&1
    collect_lparstat_info > "$LPAR_FILE" 2>&1

    cat "$VM_FILE"

    METRIC_VCPU=$(awk -F: '/Online Virtual CPUs/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$LPAR_FILE")
    [ -n "$METRIC_VCPU" ] || METRIC_VCPU=1

    PERF_LINE=$(awk '
        /^[[:space:]]*r[[:space:]]+b[[:space:]]+/ {
            for (i=1; i<=NF; i++) {
                if ($i=="r") ridx=i
                if ($i=="pi") piidx=i
                if ($i=="po") poidx=i
                if ($i=="us") usidx=i
                if ($i=="id") ididx=i
                if ($i=="wa") waidx=i
            }
            next
        }
        ridx && $1 ~ /^[0-9]+$/ {
            r=$ridx; pi=$piidx; po=$poidx; us=$usidx; id=$ididx; wa=$waidx
        }
        END {
            if (r != "") print r, pi, po, us, id, wa
        }
    ' "$VM_FILE")

    set -- $PERF_LINE
    METRIC_RUNQ="$1"
    METRIC_PAGEIN="$2"
    METRIC_PAGEOUT="$3"
    metric_us="$4"
    metric_id="$5"
    METRIC_IOWAIT="$6"

    if [ -z "$METRIC_RUNQ" ]; then
        echo ""
        echo "Performance Health: WARNING - unable to parse vmstat interval data"
        PERF_STATUS=1
        set_overall_status 1
        return
    fi

    METRIC_CPU_BUSY=$(awk -v id="$metric_id" -v wa="$METRIC_IOWAIT" 'BEGIN{printf "%.0f", 100-id-wa}')
    runq_per_cpu=$(awk -v r="$METRIC_RUNQ" -v c="$METRIC_VCPU" 'BEGIN{if(c<=0)c=1; printf "%.2f", r/c}')

    echo ""
    echo "Latest interval metrics:"
    echo "  Virtual CPUs        : $METRIC_VCPU"
    echo "  Run queue           : $METRIC_RUNQ"
    echo "  Run queue / vCPU    : $runq_per_cpu"
    echo "  CPU busy            : ${METRIC_CPU_BUSY}%"
    echo "  I/O wait            : ${METRIC_IOWAIT}%"
    echo "  Page-ins            : $METRIC_PAGEIN"
    echo "  Page-outs           : $METRIC_PAGEOUT"

    status=0

    if float_ge "$METRIC_CPU_BUSY" "$CPU_CRIT"; then
        echo "  CPU                 : CRITICAL"
        status=2
    elif float_ge "$METRIC_CPU_BUSY" "$CPU_WARN"; then
        echo "  CPU                 : WARNING"
        [ "$status" -lt 1 ] && status=1
    else
        echo "  CPU                 : OK"
    fi

    if float_ge "$METRIC_IOWAIT" "$IOWAIT_CRIT"; then
        echo "  I/O wait            : CRITICAL"
        status=2
    elif float_ge "$METRIC_IOWAIT" "$IOWAIT_WARN"; then
        echo "  I/O wait            : WARNING"
        [ "$status" -lt 1 ] && status=1
    else
        echo "  I/O wait            : OK"
    fi

    if float_ge "$runq_per_cpu" "$RUNQ_PER_CPU_CRIT"; then
        echo "  CPU run queue       : CRITICAL"
        status=2
    elif float_ge "$runq_per_cpu" "$RUNQ_PER_CPU_WARN"; then
        echo "  CPU run queue       : WARNING"
        [ "$status" -lt 1 ] && status=1
    else
        echo "  CPU run queue       : OK"
    fi

    if float_ge "$METRIC_PAGEOUT" "$PAGEOUT_CRIT"; then
        echo "  Paging activity     : CRITICAL"
        status=2
    elif float_ge "$METRIC_PAGEOUT" "$PAGEOUT_WARN"; then
        echo "  Paging activity     : WARNING"
        [ "$status" -lt 1 ] && status=1
    else
        echo "  Paging activity     : OK"
    fi

    PERF_STATUS="$status"
    set_overall_status "$status"
    echo "Performance Health: $(status_name "$status")"
}

check_paging()
{
    separator "PAGING SPACE"

    echo "Paging Detail:"
    collect_lsps_detail
    echo ""

    PAGING_FILE="${TMP_BASE}.paging"
    collect_lsps_summary > "$PAGING_FILE"
    cat "$PAGING_FILE"

    METRIC_PAGING_PERCENT=$(awk '
        {
            for(i=1;i<=NF;i++) {
                if ($i ~ /^[0-9]+%$/) {
                    gsub("%","",$i); v=$i
                }
            }
        }
        END{if(v!="")print v}
    ' "$PAGING_FILE")

    if [ -z "$METRIC_PAGING_PERCENT" ]; then
        echo "Paging Health: WARNING - unable to determine utilisation"
        PAGING_STATUS=1
        set_overall_status 1
    elif [ "$METRIC_PAGING_PERCENT" -ge "$PAGING_CRIT" ]; then
        echo "Paging Health: CRITICAL - ${METRIC_PAGING_PERCENT}% used"
        PAGING_STATUS=2
        set_overall_status 2
    elif [ "$METRIC_PAGING_PERCENT" -ge "$PAGING_WARN" ]; then
        echo "Paging Health: WARNING - ${METRIC_PAGING_PERCENT}% used"
        PAGING_STATUS=1
        set_overall_status 1
    else
        echo "Paging Health: OK - ${METRIC_PAGING_PERCENT}% used"
        PAGING_STATUS=0
    fi

    echo ""
    echo "Memory Summary:"
    collect_svmon
}

check_filesystems()
{
    separator "FILESYSTEMS"

    DF_FILE="${TMP_BASE}.df"
    collect_df > "$DF_FILE"
    cat "$DF_FILE"

    echo ""
    echo "Filesystem Health:"

    awk -v warn="$FS_WARN" -v crit="$FS_CRIT" -v iwarn="$INODE_WARN" -v icrit="$INODE_CRIT" '
        NR > 1 {
            used=$4; iused=$6; mountpoint=$7
            gsub("%","",used); gsub("%","",iused)
            if (used !~ /^[0-9]+$/) next

            level=0
            reason=""
            if (used >= crit) { level=2; reason="space" }
            else if (used >= warn) { level=1; reason="space" }

            if (iused ~ /^[0-9]+$/) {
                if (iused >= icrit) { level=2; reason=(reason?reason"+inode":"inode") }
                else if (iused >= iwarn && level < 1) { level=1; reason="inode" }
            }

            if (level==2) {
                printf "CRITICAL: %-20s space=%s%% inode=%s%% (%s)\n", mountpoint, used, iused, reason
                critical=1
            } else if (level==1) {
                printf "WARNING : %-20s space=%s%% inode=%s%% (%s)\n", mountpoint, used, iused, reason
                warning=1
            } else {
                printf "OK      : %-20s space=%s%% inode=%s%%\n", mountpoint, used, iused
            }
        }
        END { if(critical) exit 2; if(warning) exit 1; exit 0 }
    ' "$DF_FILE"
    fs_rc=$?

    echo ""
    echo "Expected mount validation:"
    mount_rc=0
    for mnt in $EXPECTED_MOUNTS; do
        if awk -v m="$mnt" 'NR>1 && $7==m {found=1} END{exit found?0:1}' "$DF_FILE"; then
            echo "OK      : $mnt is mounted"
        else
            echo "CRITICAL: expected filesystem $mnt is not mounted"
            mount_rc=2
        fi
    done

    FS_STATUS="$fs_rc"
    [ "$mount_rc" -gt "$FS_STATUS" ] && FS_STATUS="$mount_rc"
    set_overall_status "$FS_STATUS"
}

check_vgs_lvs()
{
    separator "VOLUME GROUPS / LOGICAL VOLUMES"

    ALL_VG_FILE="${TMP_BASE}.allvgs"
    ACTIVE_VG_FILE="${TMP_BASE}.activevgs"
    collect_lsvg > "$ALL_VG_FILE"
    collect_lsvg_active > "$ACTIVE_VG_FILE"

    echo "Configured Volume Groups:"
    cat "$ALL_VG_FILE"
    echo ""
    echo "Active Volume Groups:"
    cat "$ACTIVE_VG_FILE"

    status=0

    if [ -n "$EXPECTED_ACTIVE_VGS" ]; then
        echo ""
        echo "Expected active VG validation:"
        for vg in $EXPECTED_ACTIVE_VGS; do
            if grep -qx "$vg" "$ACTIVE_VG_FILE" 2>/dev/null; then
                echo "OK      : $vg active"
            else
                echo "CRITICAL: $vg is expected to be active but is not"
                status=2
            fi
        done
    fi

    echo ""
    echo "Active VG integrity:"
    while read vg; do
        [ -n "$vg" ] || continue
        VG_DETAIL="${TMP_BASE}.vg.${vg}"
        VG_LVS="${TMP_BASE}.lv.${vg}"
        collect_lsvg_detail "$vg" > "$VG_DETAIL" 2>&1
        collect_lsvg_lvs "$vg" > "$VG_LVS" 2>&1

        stale_pps=$(awk '{for(i=1;i<=NF;i++) if($i=="STALE" && $(i+1)=="PPs:"){print $(i+2); exit}}' "$VG_DETAIL")
        stale_pvs=$(awk '{for(i=1;i<=NF;i++) if($i=="STALE" && $(i+1)=="PVs:"){print $(i+2); exit}}' "$VG_DETAIL")
        free_pps=$(awk '{for(i=1;i<=NF;i++) if($i=="FREE" && $(i+1)=="PPs:"){print $(i+2); exit}}' "$VG_DETAIL")
        [ -n "$stale_pps" ] || stale_pps=0
        [ -n "$stale_pvs" ] || stale_pvs=0
        [ -n "$free_pps" ] || free_pps="unknown"

        if [ "$stale_pps" -gt 0 ] 2>/dev/null || [ "$stale_pvs" -gt 0 ] 2>/dev/null; then
            echo "CRITICAL: $vg stale_pvs=$stale_pvs stale_pps=$stale_pps free_pps=$free_pps"
            status=2
        else
            echo "OK      : $vg stale_pvs=0 stale_pps=0 free_pps=$free_pps"
        fi

        if grep '/stale' "$VG_LVS" >/dev/null 2>&1; then
            echo "CRITICAL: $vg contains stale logical volume copies"
            grep '/stale' "$VG_LVS"
            status=2
        fi
    done < "$ACTIVE_VG_FILE"

    VG_STATUS="$status"
    set_overall_status "$status"
}

check_physical_volumes()
{
    separator "PHYSICAL VOLUMES"

    PV_FILE="${TMP_BASE}.lspv"
    collect_lspv > "$PV_FILE"
    cat "$PV_FILE"

    echo ""
    echo "Physical Volume Health:"

    awk '
        NF >= 4 {
            state=tolower($4)
            if(state=="missing") {printf "CRITICAL: %s state=%s vg=%s\n",$1,$4,$3; crit=1}
            else if(state!="active" && state!="concurrent") {printf "WARNING : %s state=%s vg=%s\n",$1,$4,$3; warn=1}
            else printf "OK      : %s state=%s vg=%s\n",$1,$4,$3
        }
        END{if(crit)exit 2;if(warn)exit 1;exit 0}
    ' "$PV_FILE"
    PV_STATUS=$?
    set_overall_status "$PV_STATUS"
}

check_devices()
{
    separator "DEVICE STATE"

    DISK_FILE="${TMP_BASE}.lsdev.disk"
    ADAPTER_FILE="${TMP_BASE}.lsdev.adapter"
    PV_FILE="${TMP_BASE}.lspv.device"
    collect_lsdev_disks > "$DISK_FILE"
    collect_lsdev_adapters > "$ADAPTER_FILE"
    collect_lspv > "$PV_FILE"

    echo "Disks:"
    cat "$DISK_FILE"
    echo ""
    echo "Adapters:"
    cat "$ADAPTER_FILE"
    echo ""
    echo "Device Health:"

    status=0

    awk 'NR==FNR { if(NF>=4 && $3!="None") managed[$1]=1; next }
         managed[$1] && $2!="Available" {printf "CRITICAL: managed disk %s is %s\n",$1,$2; bad=1}
         END{exit bad?2:0}' "$PV_FILE" "$DISK_FILE"
    rc=$?
    [ "$rc" -eq 0 ] && echo "OK      : all managed disks are Available"
    [ "$rc" -gt "$status" ] && status="$rc"

    for adapter in $REQUIRED_ADAPTERS; do
        state=$(awk -v a="$adapter" '$1==a {print $2; exit}' "$ADAPTER_FILE")
        if [ "$state" = "Available" ]; then
            echo "OK      : required adapter $adapter Available"
        else
            echo "CRITICAL: required adapter $adapter state=${state:-missing}"
            status=2
        fi
    done

    awk '$1 ~ /^fcs[0-9]+$/ && $2!="Available" {printf "WARNING : FC adapter %s is %s\n",$1,$2; bad=1}
         END{exit bad?1:0}' "$ADAPTER_FILE"
    rc=$?
    [ "$rc" -gt "$status" ] && status="$rc"

    if [ "$COLLECT_FCSTAT" -eq 1 ]; then
        echo ""
        echo "FC adapter statistics (evidence only):"
        awk '$1 ~ /^fcs[0-9]+$/ && $2=="Available" {print $1}' "$ADAPTER_FILE" | while read fcs; do
            echo "--- $fcs ---"
            collect_fcstat "$fcs" 2>&1
        done
    fi

    DEVICE_STATUS="$status"
    set_overall_status "$status"
}

check_mpio()
{
    separator "STORAGE / MPIO PATHS"

    PATH_FILE="${TMP_BASE}.lspath"
    collect_lspath > "$PATH_FILE"
    cat "$PATH_FILE"

    echo ""
    echo "MPIO Health:"

    awk -v metricfile="${TMP_BASE}.mpio.metrics" '
        NF>=2 {
            state=$1; disk=$2
            if(disk !~ /^hdisk/) next
            seen[disk]=1
            if(state=="Enabled") enabled[disk]++
            else {nonenabled[disk]++; if(state=="Failed" || state=="Missing") failed[disk]++}
        }
        END {
            totalfailed=0
            for(disk in seen) {
                totalfailed += failed[disk]
                if(enabled[disk]==0) {printf "CRITICAL: %s has no Enabled paths\n",disk; crit=1}
                else if(nonenabled[disk]>0) {printf "WARNING : %s enabled=%d non_enabled=%d\n",disk,enabled[disk],nonenabled[disk]; warn=1}
                else printf "OK      : %s enabled_paths=%d\n",disk,enabled[disk]
            }
            print "__FAILED_PATHS__=" totalfailed > metricfile
            if(crit)exit 2;if(warn)exit 1;exit 0
        }
    ' "$PATH_FILE"
    MPIO_STATUS=$?
    METRIC_FAILED_PATHS=$(awk -F= '/__FAILED_PATHS__/ {print $2}' "${TMP_BASE}.mpio.metrics")
    [ -n "$METRIC_FAILED_PATHS" ] || METRIC_FAILED_PATHS=0
    set_overall_status "$MPIO_STATUS"
}

check_disk_io()
{
    separator "DISK I/O"

    IO_FILE="${TMP_BASE}.iostat"
    collect_iostat > "$IO_FILE" 2>&1
    cat "$IO_FILE"

    echo ""
    echo "Disk I/O Health:"

    IO_METRICS=$(awk -v metricfile="${TMP_BASE}.diskbusy" '
        /^Disks:/ {delete busy; inblock=1; next}
        inblock && $1 ~ /^hdisk[0-9]+$/ && $2 ~ /^[0-9.]+$/ {busy[$1]=$2}
        END {
            max=0
            for(d in busy) if(busy[d]>max) max=busy[d]
            print max
            for(d in busy) print d, busy[d] > metricfile
        }
    ' "$IO_FILE")

    METRIC_MAX_DISK_BUSY="$IO_METRICS"
    [ -n "$METRIC_MAX_DISK_BUSY" ] || METRIC_MAX_DISK_BUSY=0

    status=0
    while read disk busy; do
        [ -n "$disk" ] || continue
        if float_ge "$busy" "$DISK_BUSY_CRIT"; then
            echo "CRITICAL: $disk tm_act=${busy}%"
            status=2
        elif float_ge "$busy" "$DISK_BUSY_WARN"; then
            echo "WARNING : $disk tm_act=${busy}%"
            [ "$status" -lt 1 ] && status=1
        else
            echo "OK      : $disk tm_act=${busy}%"
        fi
    done < "${TMP_BASE}.diskbusy"

    if [ ! -s "${TMP_BASE}.diskbusy" ]; then
        echo "WARNING : unable to parse disk utilisation from iostat"
        status=1
    fi

    IO_STATUS="$status"
    set_overall_status "$status"
}

check_errpt()
{
    separator "AIX ERROR REPORT"

    ERRPT_FILE="${TMP_BASE}.errpt"
    collect_errpt > "$ERRPT_FILE" 2>&1
    cat "$ERRPT_FILE"

    echo ""
    if [ -n "$ERRPT_START" ]; then
        echo "Scope: entries since $ERRPT_START"
        enforce=1
    elif [ "$ERRPT_ENFORCE_ALL" -eq 1 ]; then
        echo "Scope: entire error log (enforced)"
        enforce=1
    else
        echo "Scope: entire error log (historical permanent errors capped at WARNING)"
        enforce=0
    fi

    awk -v enforce="$enforce" '
        NR>1 {
            type=$3; class=$4; resource=$5
            if(type=="P" && class=="H") {
                if(enforce) {printf "CRITICAL: permanent hardware error resource=%s\n",resource; crit=1}
                else {printf "WARNING : historical permanent hardware error resource=%s\n",resource; warn=1}
            } else if(type=="P") {
                printf "WARNING : permanent non-hardware error resource=%s\n",resource; warn=1
            } else if(type=="T" && class=="H") {
                printf "WARNING : temporary hardware error resource=%s\n",resource; warn=1
            }
        }
        END{if(crit)exit 2;if(warn)exit 1;print "OK      : no actionable errors detected";exit 0}
    ' "$ERRPT_FILE"
    ERRPT_STATUS=$?
    set_overall_status "$ERRPT_STATUS"
}

check_network()
{
    separator "NETWORK"

    IF_FILE="${TMP_BASE}.ifconfig"
    RT_FILE="${TMP_BASE}.routes"
    collect_ifconfig > "$IF_FILE" 2>&1
    collect_routes > "$RT_FILE" 2>&1

    echo "Interfaces:"
    cat "$IF_FILE"
    echo ""
    echo "Routing Table:"
    cat "$RT_FILE"

    status=0

    if awk '/^en[0-9]+:/ && /<[^>]*UP/ {found=1} END{exit found?0:1}' "$IF_FILE"; then
        echo "OK      : at least one non-loopback interface is UP"
    else
        echo "CRITICAL: no UP en* network interface detected"
        status=2
    fi

    gateway=$(awk '$1=="default" {print $2; exit}' "$RT_FILE")
    echo ""
    if [ -n "$gateway" ]; then
        echo "OK      : default gateway=$gateway"
    else
        echo "CRITICAL: no default route detected"
        status=2
    fi

    if [ "$PING_GATEWAY" -eq 1 ] && [ -n "$gateway" ]; then
        if [ "$MOCK_MODE" -eq 1 ]; then
            [ "$MOCK_PROFILE" = "degraded" ] && ping_rc=1 || ping_rc=0
        else
            ping -c 2 "$gateway" >/dev/null 2>&1
            ping_rc=$?
        fi
        if [ "$ping_rc" -eq 0 ]; then
            echo "OK      : gateway responds to ICMP"
        else
            echo "WARNING : gateway did not respond to ICMP"
            [ "$status" -lt 1 ] && status=1
        fi
    fi

    if [ -n "$DNS_TEST_HOST" ]; then
        if [ "$MOCK_MODE" -eq 1 ]; then
            [ "$MOCK_PROFILE" = "degraded" ] && dns_rc=1 || dns_rc=0
        elif command_exists host; then
            host "$DNS_TEST_HOST" >/dev/null 2>&1; dns_rc=$?
        elif command_exists nslookup; then
            nslookup "$DNS_TEST_HOST" >/dev/null 2>&1; dns_rc=$?
        else
            dns_rc=2
        fi

        if [ "$dns_rc" -eq 0 ]; then
            echo "OK      : DNS resolves $DNS_TEST_HOST"
        elif [ "$dns_rc" -eq 2 ]; then
            echo "WARNING : no supported DNS test utility found"
            [ "$status" -lt 1 ] && status=1
        else
            echo "CRITICAL: DNS resolution failed for $DNS_TEST_HOST"
            status=2
        fi
    fi

    NETWORK_STATUS="$status"
    set_overall_status "$status"
}

check_services()
{
    separator "SYSTEM SERVICES"

    status=0
    for subsystem in $CRITICAL_SUBSYSTEMS; do
        SRC_FILE="${TMP_BASE}.src.${subsystem}"
        collect_lssrc "$subsystem" > "$SRC_FILE" 2>&1
        cat "$SRC_FILE"
        if grep '[[:space:]]active[[:space:]]*$' "$SRC_FILE" >/dev/null 2>&1; then
            echo "OK      : $subsystem active"
        else
            echo "CRITICAL: $subsystem is not active"
            status=2
        fi
        echo ""
    done

    SERVICE_STATUS="$status"
    set_overall_status "$status"
}

check_ntp()
{
    separator "TIME SYNCHRONISATION"

    SRC_FILE="${TMP_BASE}.ntp"
    collect_lssrc "$NTP_SUBSYSTEM" > "$SRC_FILE" 2>&1
    cat "$SRC_FILE"

    if grep '[[:space:]]active[[:space:]]*$' "$SRC_FILE" >/dev/null 2>&1; then
        echo "NTP Health: OK - $NTP_SUBSYSTEM active"
        NTP_STATUS=0
    elif [ "$REQUIRE_NTP" -eq 1 ]; then
        echo "NTP Health: CRITICAL - required subsystem $NTP_SUBSYSTEM is not active"
        NTP_STATUS=2
        set_overall_status 2
    else
        echo "NTP Health: N/A - $NTP_SUBSYSTEM not active and not configured as required"
        NTP_STATUS=0
    fi
}

check_dump()
{
    separator "SYSTEM DUMP CONFIGURATION"

    DUMP_FILE="${TMP_BASE}.dump"
    collect_sysdumpdev > "$DUMP_FILE" 2>&1
    cat "$DUMP_FILE"

    primary=$(awk '$1=="primary" {print $2; exit}' "$DUMP_FILE")
    case "$primary" in
        ""|/dev/sysdumpnull|sysdumpnull|none|None)
            echo "Dump Health: CRITICAL - no usable primary dump device configured"
            DUMP_STATUS=2
            set_overall_status 2
            ;;
        *)
            echo "Dump Health: OK - primary=$primary"
            DUMP_STATUS=0
            ;;
    esac
}

check_powerha()
{
    separator "POWERHA"

    collect_powerha_detail
    echo ""

    if [ "$MOCK_MODE" -eq 1 ] || command_exists clmgr; then
        POWERHA_STATE=$(collect_powerha_state 2>/dev/null | tail -1 | tr -d '[:space:]')
        [ -n "$POWERHA_STATE" ] || POWERHA_STATE="UNKNOWN"

        if [ "$POWERHA_STATE" = "STABLE" ]; then
            echo "PowerHA Health: OK - cluster state STABLE"
            POWERHA_STATUS=0
        else
            echo "PowerHA Health: CRITICAL - cluster state $POWERHA_STATE"
            POWERHA_STATUS=2
            set_overall_status 2
        fi
    else
        POWERHA_STATE="NOT_INSTALLED"
        if [ "$POWERHA_REQUIRED" -eq 1 ]; then
            echo "PowerHA Health: CRITICAL - PowerHA required but clmgr not detected"
            POWERHA_STATUS=2
            set_overall_status 2
        else
            echo "PowerHA Health: N/A - PowerHA not detected"
            POWERHA_STATUS=0
        fi
    fi
}

###############################################################################
# MACHINE-READABLE SUMMARY
###############################################################################

write_summary()
{
    aix_level=$(collect_oslevel 2>/dev/null | head -1)
    cat > "$SUMMARY_FILE" <<EOF_SUMMARY
HOST=$HOST_SHORT
CHECK_TYPE=$CHECK_TYPE
TIMESTAMP=$TIMESTAMP
AIX_LEVEL=$aix_level
OS_STATUS=$(status_name "$OS_STATUS")
PERFORMANCE_STATUS=$(status_name "$PERF_STATUS")
PAGING_STATUS=$(status_name "$PAGING_STATUS")
FILESYSTEM_STATUS=$(status_name "$FS_STATUS")
VG_LV_STATUS=$(status_name "$VG_STATUS")
PV_STATUS=$(status_name "$PV_STATUS")
DEVICE_STATUS=$(status_name "$DEVICE_STATUS")
MPIO_STATUS=$(status_name "$MPIO_STATUS")
DISK_IO_STATUS=$(status_name "$IO_STATUS")
ERRPT_STATUS=$(status_name "$ERRPT_STATUS")
NETWORK_STATUS=$(status_name "$NETWORK_STATUS")
SERVICE_STATUS=$(status_name "$SERVICE_STATUS")
NTP_STATUS=$(status_name "$NTP_STATUS")
DUMP_STATUS=$(status_name "$DUMP_STATUS")
POWERHA_STATUS=$(status_name "$POWERHA_STATUS")
POWERHA_STATE=$POWERHA_STATE
VCPU=$METRIC_VCPU
RUN_QUEUE=$METRIC_RUNQ
CPU_BUSY_PERCENT=$METRIC_CPU_BUSY
IOWAIT_PERCENT=$METRIC_IOWAIT
PAGE_IN=$METRIC_PAGEIN
PAGE_OUT=$METRIC_PAGEOUT
PAGING_USED_PERCENT=$METRIC_PAGING_PERCENT
MAX_DISK_BUSY_PERCENT=$METRIC_MAX_DISK_BUSY
FAILED_MPIO_PATHS=$METRIC_FAILED_PATHS
OVERALL_STATUS=$(status_name "$OVERALL_STATUS")
OVERALL_CODE=$OVERALL_STATUS
EOF_SUMMARY
}

###############################################################################
# MAIN
###############################################################################

main()
{
    if [ "$MOCK_MODE" -ne 1 ]; then
        system_type=$(uname -s 2>/dev/null)
        if [ "$system_type" != "AIX" ]; then
            echo "ERROR: real mode can only run on AIX."
            echo "For development use MOCK_MODE=1."
            return 3
        fi
    fi

    echo "======================================================================"
    echo " AIX INFRASTRUCTURE RELIABILITY HEALTH CHECK"
    echo "======================================================================"
    echo "Generated : $(date)"
    echo "Host      : $HOST_SHORT"
    echo "Check type: $CHECK_TYPE"
    if [ "$MOCK_MODE" -eq 1 ]; then
        echo "Mode      : MOCK ($MOCK_PROFILE)"
    else
        echo "Mode      : REAL AIX"
    fi

    separator "SYSTEM / LPAR INFORMATION"
    echo "Hostname: $HOST_SHORT"
    echo "AIX Level: $(collect_oslevel)"
    echo "Uptime:"
    collect_uptime
    echo ""
    echo "LPAR Information:"
    collect_lparstat_info

    check_os_integrity
    check_performance
    check_paging
    check_filesystems
    check_vgs_lvs
    check_physical_volumes
    check_devices
    check_mpio
    check_disk_io
    check_errpt
    check_network
    check_services
    check_ntp
    check_dump
    check_powerha

    separator "RELIABILITY SUMMARY"
    echo "AIX software       : $(status_name "$OS_STATUS")"
    echo "CPU / performance  : $(status_name "$PERF_STATUS")"
    echo "Paging             : $(status_name "$PAGING_STATUS")"
    echo "Filesystems        : $(status_name "$FS_STATUS")"
    echo "VG / LV integrity  : $(status_name "$VG_STATUS")"
    echo "Physical volumes   : $(status_name "$PV_STATUS")"
    echo "Device state       : $(status_name "$DEVICE_STATUS")"
    echo "MPIO paths         : $(status_name "$MPIO_STATUS")"
    echo "Disk I/O           : $(status_name "$IO_STATUS")"
    echo "AIX error log      : $(status_name "$ERRPT_STATUS")"
    echo "Network            : $(status_name "$NETWORK_STATUS")"
    echo "Critical services  : $(status_name "$SERVICE_STATUS")"
    echo "Time sync          : $(status_name "$NTP_STATUS")"
    echo "Dump configuration : $(status_name "$DUMP_STATUS")"
    echo "PowerHA            : $(status_name "$POWERHA_STATUS")"
    echo ""
    echo "OVERALL HEALTH     : $(status_name "$OVERALL_STATUS")"

    return "$OVERALL_STATUS"
}

###############################################################################
# EXECUTION / REPORT GENERATION
###############################################################################

main > "$REPORT_FILE" 2>&1
RESULT=$?

write_summary
cat "$REPORT_FILE"

echo ""
echo "======================================================================"
echo "Text report   : $REPORT_FILE"
echo "Summary file : $SUMMARY_FILE"
echo "======================================================================"

exit "$RESULT"
