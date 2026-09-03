#!/usr/bin/ksh

###############################################################################
# AIX Infrastructure Reliability Health Check
#
# Author: Tanaka Kambasha
#
# Purpose:
#   Perform baseline AIX infrastructure health validation covering:
#     - Operating system
#     - LPAR configuration
#     - Memory / paging
#     - Filesystems
#     - Volume groups
#     - Physical volumes
#     - MPIO paths
#     - AIX error report
#     - Networking
#     - PowerHA information
#
# Modes:
#
#   Real AIX:
#       ./scripts/aix_healthcheck.sh
#
#   Mock healthy:
#       MOCK_MODE=1 MOCK_PROFILE=healthy ./scripts/aix_healthcheck.sh
#
#   Mock degraded:
#       MOCK_MODE=1 MOCK_PROFILE=degraded ./scripts/aix_healthcheck.sh
#
# Exit codes:
#       0 = OK
#       1 = WARNING
#       2 = CRITICAL
#       3 = UNKNOWN / unsupported
###############################################################################


###############################################################################
# CONFIGURATION
###############################################################################

MOCK_MODE="${MOCK_MODE:-0}"
MOCK_PROFILE="${MOCK_PROFILE:-healthy}"

CHECK_TYPE="${CHECK_TYPE:-healthcheck}"

FS_WARN="${FS_WARN:-80}"
FS_CRIT="${FS_CRIT:-90}"

PAGING_WARN="${PAGING_WARN:-70}"
PAGING_CRIT="${PAGING_CRIT:-85}"

OVERALL_STATUS=0

FS_STATUS=0
PAGING_STATUS=0
PV_STATUS=0
MPIO_STATUS=0
ERRPT_STATUS=0


###############################################################################
# PROJECT PATHS
###############################################################################

SCRIPT_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")

REPORT_DIR="${PROJECT_DIR}/reports"

if [ "$MOCK_MODE" -eq 1 ]
then
    HOST_SHORT="mock-${MOCK_PROFILE}"
else
    HOST_SHORT=$(hostname | cut -d. -f1)
fi

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

REPORT_FILE="${REPORT_DIR}/${HOST_SHORT}_${TIMESTAMP}_${CHECK_TYPE}.txt"

mkdir -p "$REPORT_DIR"

TMP_BASE="/tmp/aix_healthcheck.$$"

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


set_overall_status()
{
    NEW_STATUS="$1"

    if [ "$NEW_STATUS" -gt "$OVERALL_STATUS" ]
    then
        OVERALL_STATUS="$NEW_STATUS"
    fi
}


status_name()
{
    case "$1" in
        0)
            echo "OK"
            ;;
        1)
            echo "WARNING"
            ;;
        2)
            echo "CRITICAL"
            ;;
        *)
            echo "UNKNOWN"
            ;;
    esac
}


###############################################################################
# MOCK / REAL DATA COLLECTION
###############################################################################

collect_oslevel()
{
    if [ "$MOCK_MODE" -eq 1 ]
    then
        echo "7200-05-11-2546"
    else
        oslevel -s
    fi
}


collect_uptime()
{
    if [ "$MOCK_MODE" -eq 1 ]
    then
        echo "12:14PM up 64 days, 4:32, 3 users, load average: 0.45, 0.38, 0.31"
    else
        uptime
    fi
}


collect_lparstat()
{
    if [ "$MOCK_MODE" -eq 1 ]
    then
        cat <<EOF
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
EOF
    else
        if command -v lparstat >/dev/null 2>&1
        then
            lparstat -i
        else
            echo "lparstat command unavailable"
        fi
    fi
}


collect_lsps_summary()
{
    if [ "$MOCK_MODE" -eq 1 ]
    then

        if [ "$MOCK_PROFILE" = "degraded" ]
        then
            cat <<EOF
Total Paging Space   Percent Used
      8192MB              88%
EOF
        else
            cat <<EOF
Total Paging Space   Percent Used
      8192MB               3%
EOF
        fi

    else
        lsps -s
    fi
}


collect_lsps_detail()
{
    if [ "$MOCK_MODE" -eq 1 ]
    then

        if [ "$MOCK_PROFILE" = "degraded" ]
        then
            cat <<EOF
Page Space      Physical Volume   Volume Group    Size %Used Active Auto Type Chksum
hd6             hdisk0            rootvg        4096MB    92   yes   yes    lv     0
paging00        hdisk1            rootvg        4096MB    84   yes   yes    lv     0
EOF
        else
            cat <<EOF
Page Space      Physical Volume   Volume Group    Size %Used Active Auto Type Chksum
hd6             hdisk0            rootvg        4096MB     3   yes   yes    lv     0
paging00        hdisk1            rootvg        4096MB     2   yes   yes    lv     0
EOF
        fi

    else
        lsps -a
    fi
}


collect_svmon()
{
    if [ "$MOCK_MODE" -eq 1 ]
    then
        cat <<EOF
               size       inuse        free         pin     virtual   available
memory      8388608     5421136     2967472     621443     3921102     2819021
pg space    2097152      103441

               work        pers        clnt       other
pin          521443           0           0      100000
in use      4211021           0     1210115
EOF
    else
        svmon -G
    fi
}


collect_df()
{
    if [ "$MOCK_MODE" -eq 1 ]
    then

        if [ "$MOCK_PROFILE" = "degraded" ]
        then
            cat <<EOF
Filesystem    GB blocks      Free %Used    Iused %Iused Mounted on
/dev/hd4           5.00      4.10   18%    12000     3% /
/dev/hd2          10.00      6.20   38%    45000     8% /usr
/dev/hd9var        5.00      0.70   86%     2500     2% /var
/dev/hd3          10.00      7.90   21%     1800     1% /tmp
/dev/oraclelv    200.00     12.00   94%   450000    22% /oracle
EOF
        else
            cat <<EOF
Filesystem    GB blocks      Free %Used    Iused %Iused Mounted on
/dev/hd4           5.00      4.10   18%    12000     3% /
/dev/hd2          10.00      6.20   38%    45000     8% /usr
/dev/hd9var        5.00      3.75   25%     2500     2% /var
/dev/hd3          10.00      7.90   21%     1800     1% /tmp
/dev/oraclelv    200.00     90.00   55%   450000    22% /oracle
EOF
        fi

    else
        df -g
    fi
}


collect_lsvg()
{
    if [ "$MOCK_MODE" -eq 1 ]
    then
        cat <<EOF
rootvg
datavg
oraclevg
EOF
    else
        lsvg
    fi
}


collect_lsvg_active()
{
    if [ "$MOCK_MODE" -eq 1 ]
    then
        cat <<EOF
rootvg
datavg
oraclevg
EOF
    else
        lsvg -o
    fi
}


collect_lspv()
{
    if [ "$MOCK_MODE" -eq 1 ]
    then
        cat <<EOF
hdisk0          00f9c87a12345678                    rootvg          active
hdisk1          00f9c87a12345679                    rootvg          active
hdisk2          00f9c87a12345680                    datavg          active
hdisk3          00f9c87a12345681                    datavg          active
hdisk4          00f9c87a12345682                    oraclevg        active
hdisk5          00f9c87a12345683                    None
EOF
    else
        lspv
    fi
}


collect_lspath()
{
    if [ "$MOCK_MODE" -eq 1 ]
    then

        if [ "$MOCK_PROFILE" = "degraded" ]
        then
            cat <<EOF
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
EOF
        else
            cat <<EOF
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
EOF
        fi

    else
        lspath
    fi
}


collect_errpt()
{
    if [ "$MOCK_MODE" -eq 1 ]
    then

        if [ "$MOCK_PROFILE" = "degraded" ]
        then
            cat <<EOF
IDENTIFIER TIMESTAMP  T C RESOURCE_NAME  DESCRIPTION
2BFA76F6   0903111026 P H hdisk3         DISK OPERATION ERROR
F7FA22C9   0903110526 P H fscsi0         ADAPTER ERROR
A6DF45AA   0903103026 T S inet0          INFORMATIONAL NETWORK EVENT
EOF
        else
            cat <<EOF
IDENTIFIER TIMESTAMP  T C RESOURCE_NAME  DESCRIPTION
A6DF45AA   0903103026 T S inet0          INFORMATIONAL NETWORK EVENT
EOF
        fi

    else
        errpt
    fi
}


collect_ifconfig()
{
    if [ "$MOCK_MODE" -eq 1 ]
    then
        cat <<EOF
en0: flags=1e084863,480<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST,GROUPRT>
        inet 10.20.30.40 netmask 0xffffff00 broadcast 10.20.30.255
lo0: flags=e08084b,c0<UP,BROADCAST,LOOPBACK,RUNNING,SIMPLEX,MULTICAST>
        inet 127.0.0.1 netmask 0xff000000
EOF
    else
        ifconfig -a
    fi
}


collect_routes()
{
    if [ "$MOCK_MODE" -eq 1 ]
    then
        cat <<EOF
Routing tables
Destination        Gateway           Flags   Refs     Use  If   Exp  Groups
default            10.20.30.1        UG        8   12345  en0
10.20.30/24         10.20.30.40       U         1    2000  en0
127/8               127.0.0.1         U         4    5000  lo0
EOF
    else
        netstat -rn
    fi
}


collect_powerha()
{
    if [ "$MOCK_MODE" -eq 1 ]
    then
        cat <<EOF
PowerHA Version: 7.2.8
Cluster Name: PROD_CLUSTER
Cluster State: STABLE
Node aixdb01: UP
Node aixdb02: UP
EOF
    else

        if command -v halevel >/dev/null 2>&1
        then
            echo "PowerHA Level:"
            halevel -s
            echo ""
        fi

        if command -v clmgr >/dev/null 2>&1
        then
            echo "Cluster Information:"
            clmgr query cluster
        else
            echo "PowerHA cluster management tools not detected"
        fi
    fi
}


###############################################################################
# HEALTH CHECK FUNCTIONS
###############################################################################

check_paging()
{
    PAGING_FILE="${TMP_BASE}.paging"

    collect_lsps_summary > "$PAGING_FILE"

    cat "$PAGING_FILE"

    PAGING_PERCENT=$(awk '
        NR > 1 {
            value=$2
            gsub("%","",value)

            if (value ~ /^[0-9]+$/) {
                print value
                exit
            }
        }
    ' "$PAGING_FILE")

    echo ""

    if [ -z "$PAGING_PERCENT" ]
    then
        echo "Paging Health: WARNING - Unable to determine utilisation"

        PAGING_STATUS=1
        set_overall_status 1
        return
    fi

    if [ "$PAGING_PERCENT" -ge "$PAGING_CRIT" ]
    then
        echo "Paging Health: CRITICAL - ${PAGING_PERCENT}% used"

        PAGING_STATUS=2
        set_overall_status 2

    elif [ "$PAGING_PERCENT" -ge "$PAGING_WARN" ]
    then
        echo "Paging Health: WARNING - ${PAGING_PERCENT}% used"

        PAGING_STATUS=1
        set_overall_status 1

    else
        echo "Paging Health: OK - ${PAGING_PERCENT}% used"

        PAGING_STATUS=0
    fi
}


check_filesystems()
{
    DF_FILE="${TMP_BASE}.df"

    collect_df > "$DF_FILE"

    cat "$DF_FILE"

    echo ""
    echo "Filesystem Health:"

    awk \
        -v warn="$FS_WARN" \
        -v crit="$FS_CRIT" '
    NR > 1 {

        used=$4
        mountpoint=$7

        gsub("%","",used)

        if (used !~ /^[0-9]+$/)
            next

        if (mountpoint == "/proc")
            next

        if (used >= crit) {
            printf "CRITICAL: %-20s %s%% used\n", mountpoint, used
            critical_found=1
        }
        else if (used >= warn) {
            printf "WARNING : %-20s %s%% used\n", mountpoint, used
            warning_found=1
        }
        else {
            printf "OK      : %-20s %s%% used\n", mountpoint, used
        }
    }

    END {

        if (critical_found)
            exit 2

        if (warning_found)
            exit 1

        exit 0
    }
    ' "$DF_FILE"

    RESULT=$?

    FS_STATUS="$RESULT"
    set_overall_status "$RESULT"
}


check_physical_volumes()
{
    PV_FILE="${TMP_BASE}.lspv"

    collect_lspv > "$PV_FILE"

    cat "$PV_FILE"

    echo ""
    echo "Physical Volume Health:"

    awk '
    NF >= 4 {

        state=tolower($4)

        if (state == "missing") {
            printf "CRITICAL: %s state is %s\n", $1, $4
            critical_found=1
        }
        else if (state != "active" && state != "concurrent") {
            printf "WARNING : %s state is %s\n", $1, $4
            warning_found=1
        }
        else {
            printf "OK      : %s %s\n", $1, $4
        }
    }

    END {

        if (critical_found)
            exit 2

        if (warning_found)
            exit 1

        exit 0
    }
    ' "$PV_FILE"

    RESULT=$?

    PV_STATUS="$RESULT"
    set_overall_status "$RESULT"
}


check_mpio()
{
    PATH_FILE="${TMP_BASE}.lspath"

    collect_lspath > "$PATH_FILE"

    cat "$PATH_FILE"

    echo ""
    echo "MPIO Health:"

    awk '
    NF >= 2 {

        state=$1
        disk=$2

        if (disk !~ /^hdisk/)
            next

        seen[disk]=1

        if (state == "Enabled")
            enabled[disk]++
        else
            failed[disk]++
    }

    END {

        for (disk in seen) {

            if (enabled[disk] == 0) {

                printf "CRITICAL: %s has no Enabled paths\n", disk
                critical_found=1
            }

            else if (failed[disk] > 0) {

                printf "WARNING : %s has %d Enabled and %d non-Enabled path(s)\n",
                       disk,
                       enabled[disk],
                       failed[disk]

                warning_found=1
            }

            else {

                printf "OK      : %s has %d Enabled path(s)\n",
                       disk,
                       enabled[disk]
            }
        }

        if (critical_found)
            exit 2

        if (warning_found)
            exit 1

        exit 0
    }
    ' "$PATH_FILE"

    RESULT=$?

    MPIO_STATUS="$RESULT"
    set_overall_status "$RESULT"
}


check_errpt()
{
    ERRPT_FILE="${TMP_BASE}.errpt"

    collect_errpt > "$ERRPT_FILE"

    cat "$ERRPT_FILE"

    echo ""
    echo "Error Report Health:"

    awk '
    NR > 1 {

        type=$3
        class=$4

        if (type == "P" && class == "H") {

            printf "CRITICAL: Permanent hardware error: %s %s\n",
                   $5,
                   $6

            critical_found=1
        }

        else if (type == "P") {

            printf "WARNING : Permanent error detected: %s %s\n",
                   $5,
                   $6

            warning_found=1
        }
    }

    END {

        if (critical_found)
            exit 2

        if (warning_found)
            exit 1

        print "OK      : No permanent errors detected"
        exit 0
    }
    ' "$ERRPT_FILE"

    RESULT=$?

    ERRPT_STATUS="$RESULT"
    set_overall_status "$RESULT"
}


###############################################################################
# MAIN
###############################################################################

main()
{
    if [ "$MOCK_MODE" -ne 1 ]
    then

        SYSTEM_TYPE=$(uname -s)

        if [ "$SYSTEM_TYPE" != "AIX" ]
        then
            echo "ERROR:"
            echo "Real mode can only run on AIX."
            echo ""
            echo "For development use:"
            echo "MOCK_MODE=1 MOCK_PROFILE=healthy $0"

            return 3
        fi
    fi


    echo "======================================================================"
    echo " AIX INFRASTRUCTURE RELIABILITY HEALTH CHECK"
    echo "======================================================================"

    echo ""
    echo "Generated:"
    date

    echo ""
    echo "Mode:"

    if [ "$MOCK_MODE" -eq 1 ]
    then
        echo "MOCK (${MOCK_PROFILE})"
    else
        echo "REAL AIX"
    fi


    separator "SYSTEM INFORMATION"

    echo "Hostname:"
    echo "$HOST_SHORT"

    echo ""
    echo "AIX Level:"
    collect_oslevel

    echo ""
    echo "Uptime:"
    collect_uptime


    separator "LPAR INFORMATION"

    collect_lparstat


    separator "MEMORY AND PAGING"

    echo "Paging Detail:"
    collect_lsps_detail

    echo ""
    echo "Paging Summary / Health:"
    check_paging

    echo ""
    echo "Memory Summary:"
    collect_svmon


    separator "FILESYSTEMS"

    check_filesystems


    separator "VOLUME GROUPS"

    echo "Configured Volume Groups:"
    collect_lsvg

    echo ""
    echo "Active Volume Groups:"
    collect_lsvg_active


    separator "PHYSICAL VOLUMES"

    check_physical_volumes


    separator "STORAGE / MPIO PATHS"

    check_mpio


    separator "AIX ERROR REPORT"

    check_errpt


    separator "NETWORK"

    echo "Interfaces:"
    collect_ifconfig

    echo ""
    echo "Routing Table:"
    collect_routes


    separator "POWERHA"

    collect_powerha


    separator "RELIABILITY SUMMARY"

    echo "Paging        : $(status_name "$PAGING_STATUS")"
    echo "Filesystems   : $(status_name "$FS_STATUS")"
    echo "Physical Vols : $(status_name "$PV_STATUS")"
    echo "MPIO Paths    : $(status_name "$MPIO_STATUS")"
    echo "AIX Error Log : $(status_name "$ERRPT_STATUS")"

    echo ""
    echo "OVERALL HEALTH: $(status_name "$OVERALL_STATUS")"

    return "$OVERALL_STATUS"
}


###############################################################################
# EXECUTION / REPORT GENERATION
###############################################################################

main > "$REPORT_FILE" 2>&1

RESULT=$?

cat "$REPORT_FILE"

echo ""
echo "======================================================================"
echo "Report saved to:"
echo "$REPORT_FILE"
echo "======================================================================"

exit "$RESULT"