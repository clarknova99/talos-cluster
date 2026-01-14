#!/usr/bin/env bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to convert memory to GiB
convert_to_gib() {
    local mem="$1"
    if [ -z "$mem" ] || [ "$mem" = "N/A" ] || [ "$mem" = "-" ]; then
        echo "0"
        return
    fi

    # Remove any trailing whitespace, quotes, and comments
    mem=$(echo "$mem" | sed 's/#.*//' | tr -d ' "' | sed 's/^-$//')

    # Extract number and unit
    if [[ "$mem" =~ ^([0-9.]+)([A-Za-z]*)$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"

        case "$unit" in
            Gi|G) echo "$num" ;;
            Mi|M) echo "scale=3; $num / 1024" | bc -l ;;
            Ki|K) echo "scale=6; $num / (1024 * 1024)" | bc -l ;;
            Ti|T) echo "scale=3; $num * 1024" | bc -l ;;
            *) echo "scale=6; $num / (1024 * 1024 * 1024)" | bc -l ;;  # Assume bytes
        esac
    else
        echo "0"
    fi
}

# Function to convert CPU to millicores
convert_to_millicores() {
    local cpu="$1"
    if [ -z "$cpu" ] || [ "$cpu" = "N/A" ] || [ "$cpu" = "-" ]; then
        echo "0"
        return
    fi

    # Remove any trailing whitespace
    cpu=$(echo "$cpu" | tr -d ' ')

    # Handle different CPU formats
    if [[ "$cpu" =~ ^([0-9.]+)m$ ]]; then
        # Already in millicores
        echo "${BASH_REMATCH[1]}"
    elif [[ "$cpu" =~ ^([0-9.]+)$ ]]; then
        # In cores, convert to millicores
        echo "scale=0; ${BASH_REMATCH[1]} * 1000" | bc -l
    else
        echo "0"
    fi
}

# Default options
OUTPUT_FORMAT="table"
FILTER_NAMESPACE=""
MIN_LIMIT_GIB=0
SAMPLE_COUNT=3
SAMPLE_INTERVAL=5
SORT_BY_DISCREPANCY=0

# Usage function
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Generate a comprehensive report of ALL HelmReleases in the cluster with resource
configurations and real-time usage metrics (CPU + Memory).

OPTIONS:
    -h, --help              Show this help message
    -f, --format FORMAT     Output format: table, csv, markdown (default: table)
    -n, --namespace NS      Filter by namespace
    -m, --min-limit SIZE    Only show apps with memory limit >= SIZE (e.g., 1Gi, 500Mi)
    -s, --samples N         Number of samples for avg/max calculation (default: 3)
    -i, --interval SEC      Seconds between samples (default: 5)
    -d, --sort-discrepancy  Sort by memory discrepancy (limit - max usage), biggest first
    --no-color              Disable colored output

EXAMPLES:
    $0                              # Full report with 3 samples
    $0 -s 1                         # Quick report (single sample)
    $0 -s 5 -i 10                   # 5 samples, 10s apart for better avg/max
    $0 -f csv > report.csv          # Export as CSV
    $0 -n media                     # Only media namespace
    $0 -d                           # Sort by memory over-provisioning

EOF
    exit 0
}

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            ;;
        -f|--format)
            OUTPUT_FORMAT="$2"
            shift 2
            ;;
        -n|--namespace)
            FILTER_NAMESPACE="$2"
            shift 2
            ;;
        -m|--min-limit)
            MIN_LIMIT_GIB=$(convert_to_gib "$2")
            shift 2
            ;;
        -s|--samples)
            SAMPLE_COUNT="$2"
            shift 2
            ;;
        -i|--interval)
            SAMPLE_INTERVAL="$2"
            shift 2
            ;;
        -d|--sort-discrepancy)
            SORT_BY_DISCREPANCY=1
            shift
            ;;
        --no-color)
            RED=''
            GREEN=''
            YELLOW=''
            BLUE=''
            CYAN=''
            NC=''
            shift
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Check for required commands
for cmd in bc yq kubectl awk; do
    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${RED}Error: Required command '$cmd' not found. Please install it.${NC}" >&2
        exit 1
    fi
done

# Temporary files for data
tmpfile=$(mktemp)
usage_file=$(mktemp)
sample_file=$(mktemp)
trap "rm -f $tmpfile $usage_file $sample_file" EXIT

# Change to script directory if kubernetes/apps doesn't exist
if [ ! -d "kubernetes/apps" ]; then
    if [ -d "$HOME/code/talos-cluster/kubernetes/apps" ]; then
        cd "$HOME/code/talos-cluster"
    else
        echo -e "${RED}Error: Could not find kubernetes/apps directory${NC}" >&2
        exit 1
    fi
fi

echo -e "${BLUE}Collecting resource usage metrics (${SAMPLE_COUNT} samples, ${SAMPLE_INTERVAL}s interval)...${NC}" >&2

# Collect multiple samples for avg/max calculation
for sample in $(seq 1 $SAMPLE_COUNT); do
    if [ $sample -gt 1 ]; then
        echo -e "${CYAN}  Sample $sample/$SAMPLE_COUNT...${NC}" >&2
        sleep $SAMPLE_INTERVAL
    else
        echo -e "${CYAN}  Sample $sample/$SAMPLE_COUNT...${NC}" >&2
    fi

    if [ -n "$FILTER_NAMESPACE" ]; then
        kubectl top pods -n "$FILTER_NAMESPACE" --no-headers 2>/dev/null | while read -r pod cpu memory; do
            # Extract app name - handle multiple pod naming patterns:
            # Deployment: app-name-abc123def-xyz45
            # StatefulSet: app-name-0, app-name-1
            # Job/CronJob: app-name-xyz45-runner-abc12
            app_name=$(echo "$pod" | sed -E 's/-[a-z0-9]{8,10}-[a-z0-9]{5}$//' | sed -E 's/-[a-z0-9]{9,10}$//' | sed -E 's/-[0-9]+$//')
            cpu_m=$(convert_to_millicores "$cpu")
            mem_gib=$(convert_to_gib "$memory")
            echo "$app_name|$FILTER_NAMESPACE|$cpu_m|$mem_gib" >> "$sample_file"
        done 2>/dev/null || true
    else
        kubectl top pods -A --no-headers 2>/dev/null | while read -r ns pod cpu memory; do
            # Extract app name - handle multiple pod naming patterns:
            # Deployment: app-name-abc123def-xyz45
            # StatefulSet: app-name-0, app-name-1
            # Job/CronJob: app-name-xyz45-runner-abc12
            app_name=$(echo "$pod" | sed -E 's/-[a-z0-9]{8,10}-[a-z0-9]{5}$//' | sed -E 's/-[a-z0-9]{9,10}$//' | sed -E 's/-[0-9]+$//')
            cpu_m=$(convert_to_millicores "$cpu")
            mem_gib=$(convert_to_gib "$memory")
            echo "$app_name|$ns|$cpu_m|$mem_gib" >> "$sample_file"
        done 2>/dev/null || true
    fi
done

echo -e "${BLUE}Calculating average and maximum usage...${NC}" >&2

# Calculate avg and max for each app
if [ -s "$sample_file" ]; then
    sort "$sample_file" | awk -F'|' '
    {
        key = $1 "|" $2
        cpu[key] += $3
        mem[key] += $4
        count[key]++
        if ($3 > max_cpu[key]) max_cpu[key] = $3
        if ($4 > max_mem[key]) max_mem[key] = $4
    }
    END {
        for (k in count) {
            avg_cpu = cpu[k] / count[k]
            avg_mem = mem[k] / count[k]
            printf "%s|%.0f|%.3f|%.0f|%.3f\n", k, avg_cpu, avg_mem, max_cpu[k], max_mem[k]
        }
    }
    ' > "$usage_file"
fi

echo -e "${BLUE}Scanning ALL HelmReleases...${NC}" >&2

# Find ALL HelmRelease files and extract resource configs
find kubernetes/apps -name "helmrelease.yaml" -not -path "*/_archive/*" | while read -r file; do
    name=$(yq eval '.metadata.name // .spec.releaseName' "$file" 2>/dev/null | head -1)
    namespace=$(yq eval '.metadata.namespace' "$file" 2>/dev/null)

    if [ -z "$namespace" ] || [ "$namespace" = "null" ]; then
        namespace=$(echo "$file" | cut -d'/' -f3)
    fi

    # Apply namespace filter
    if [ -n "$FILTER_NAMESPACE" ] && [ "$namespace" != "$FILTER_NAMESPACE" ]; then
        continue
    fi

    # Extract CPU configs
    cpu_limit_raw=$(yq eval '.. | select(has("limits")) | .limits.cpu' "$file" 2>/dev/null | grep -v "null" | head -1 || echo "")
    cpu_request_raw=$(yq eval '.. | select(has("requests")) | .requests.cpu' "$file" 2>/dev/null | grep -v "null" | head -1 || echo "")

    # Fallback to grep for CPU
    if [ -z "$cpu_limit_raw" ]; then
        cpu_limit_raw=$(grep -A2 "limits:" "$file" | grep "cpu:" | awk '{print $2}' | tr -d '"' | head -1 || echo "")
    fi
    if [ -z "$cpu_request_raw" ]; then
        cpu_request_raw=$(grep -A2 "requests:" "$file" | grep "cpu:" | awk '{print $2}' | tr -d '"' | head -1 || echo "")
    fi

    # Extract memory configs
    mem_limit_raw=$(yq eval '.. | select(has("limits")) | .limits.memory' "$file" 2>/dev/null | grep -v "null" | head -1 || echo "")
    mem_request_raw=$(yq eval '.. | select(has("requests")) | .requests.memory' "$file" 2>/dev/null | grep -v "null" | head -1 || echo "")

    if [ -z "$mem_limit_raw" ]; then
        mem_limit_raw=$(grep -A2 "limits:" "$file" | grep "memory:" | awk '{print $2}' | tr -d '"' | head -1 || echo "")
    fi
    if [ -z "$mem_request_raw" ]; then
        mem_request_raw=$(grep -A2 "requests:" "$file" | grep "memory:" | awk '{print $2}' | tr -d '"' | head -1 || echo "")
    fi

    # Convert to normalized units
    cpu_limit_m=$(convert_to_millicores "$cpu_limit_raw")
    cpu_request_m=$(convert_to_millicores "$cpu_request_raw")
    mem_limit_gib=$(convert_to_gib "$mem_limit_raw")
    mem_request_gib=$(convert_to_gib "$mem_request_raw")

    # Get usage data for this app
    usage_line=$(grep "^$name|$namespace|" "$usage_file" 2>/dev/null | head -1 || echo "")
    if [ -n "$usage_line" ]; then
        cpu_avg=$(echo "$usage_line" | cut -d'|' -f3)
        mem_avg=$(echo "$usage_line" | cut -d'|' -f4)
        cpu_max=$(echo "$usage_line" | cut -d'|' -f5)
        mem_max=$(echo "$usage_line" | cut -d'|' -f6)
    else
        cpu_avg="0"
        mem_avg="0"
        cpu_max="0"
        mem_max="0"
    fi

    # Apply minimum limit filter
    filter_pass=1
    if [ "$MIN_LIMIT_GIB" != "0" ]; then
        if (( $(echo "$mem_limit_gib < $MIN_LIMIT_GIB" | bc -l) )); then
            filter_pass=0
        fi
    fi

    if [ "$filter_pass" = "1" ]; then
        # Calculate memory discrepancy (limit - max usage) for sorting
        if [ "$mem_limit_gib" != "0" ] && [ "$mem_max" != "0" ]; then
            mem_discrepancy=$(echo "scale=6; $mem_limit_gib - $mem_max" | bc -l)
        else
            mem_discrepancy="0"
        fi
        # Format: name|ns|cpu_lim|cpu_req|mem_lim|mem_req|cpu_avg|mem_avg|cpu_max|mem_max|file|mem_discrepancy
        echo "$name|$namespace|$cpu_limit_m|$cpu_request_m|$mem_limit_gib|$mem_request_gib|$cpu_avg|$mem_avg|$cpu_max|$mem_max|$file|$mem_discrepancy" >> "$tmpfile"
    fi
done

# Check if we found any results
if [ ! -s "$tmpfile" ]; then
    echo -e "${RED}No HelmReleases found.${NC}" >&2
    exit 1
fi

echo -e "\n${GREEN}Found $(wc -l < "$tmpfile" | tr -d ' ') HelmReleases${NC}\n" >&2

# Output based on format
case "$OUTPUT_FORMAT" in
    csv)
        if [ "$SORT_BY_DISCREPANCY" = "1" ]; then
            echo "HelmRelease,Namespace,CPU Limit (m),CPU Request (m),CPU Avg (m),CPU Max (m),Mem Limit (GiB),Mem Request (GiB),Mem Avg (GiB),Mem Max (GiB),Mem Usage %,Mem Discrepancy (GiB),Path"
        else
            echo "HelmRelease,Namespace,CPU Limit (m),CPU Request (m),CPU Avg (m),CPU Max (m),Mem Limit (GiB),Mem Request (GiB),Mem Avg (GiB),Mem Max (GiB),Mem Usage %,Path"
        fi
        # Sort by discrepancy (field 12) if requested, otherwise by mem_lim (field 5)
        if [ "$SORT_BY_DISCREPANCY" = "1" ]; then
            sort_cmd="sort -t'|' -k12 -g -r"
        else
            sort_cmd="sort -t'|' -k5 -n -r"
        fi
        eval "$sort_cmd" "$tmpfile" | while IFS='|' read -r name ns cpu_lim cpu_req mem_lim mem_req cpu_avg mem_avg cpu_max mem_max file mem_discrepancy; do
            # Format values
            cpu_lim_d=$([ "$cpu_lim" = "0" ] && echo "N/A" || printf "%.0f" "$cpu_lim")
            cpu_req_d=$([ "$cpu_req" = "0" ] && echo "N/A" || printf "%.0f" "$cpu_req")
            cpu_avg_d=$([ "$cpu_avg" = "0" ] && echo "N/A" || printf "%.0f" "$cpu_avg")
            cpu_max_d=$([ "$cpu_max" = "0" ] && echo "N/A" || printf "%.0f" "$cpu_max")
            mem_lim_d=$([ "$mem_lim" = "0" ] && echo "N/A" || printf "%.2f" "$mem_lim")
            mem_req_d=$([ "$mem_req" = "0" ] && echo "N/A" || printf "%.2f" "$mem_req")
            mem_avg_d=$([ "$mem_avg" = "0" ] && echo "N/A" || printf "%.2f" "$mem_avg")
            mem_max_d=$([ "$mem_max" = "0" ] && echo "N/A" || printf "%.2f" "$mem_max")

            if [ "$mem_lim" != "0" ] && [ "$mem_avg" != "0" ]; then
                mem_pct=$(printf "%.1f" "$(echo "scale=1; $mem_avg * 100 / $mem_lim" | bc -l)")
            else
                mem_pct="N/A"
            fi

            if [ "$SORT_BY_DISCREPANCY" = "1" ]; then
                mem_disc_d=$([ "$mem_discrepancy" = "0" ] && echo "N/A" || printf "%.2f" "$mem_discrepancy")
                echo "$name,$ns,$cpu_lim_d,$cpu_req_d,$cpu_avg_d,$cpu_max_d,$mem_lim_d,$mem_req_d,$mem_avg_d,$mem_max_d,$mem_pct,$mem_disc_d,$file"
            else
                echo "$name,$ns,$cpu_lim_d,$cpu_req_d,$cpu_avg_d,$cpu_max_d,$mem_lim_d,$mem_req_d,$mem_avg_d,$mem_max_d,$mem_pct,$file"
            fi
        done
        ;;

    table|*)
        echo "=========================================================================================================================================================================================================="
        if [ "$SORT_BY_DISCREPANCY" = "1" ]; then
            echo "HELMRELEASE RESOURCE REPORT - SORTED BY MEMORY DISCREPANCY (OVER-PROVISIONED)"
        else
            echo "HELMRELEASE RESOURCE REPORT - ALL RELEASES"
        fi
        echo "=========================================================================================================================================================================================================="
        if [ "$SORT_BY_DISCREPANCY" = "1" ]; then
            printf "%-25s %-17s | %-8s %-8s %-8s %-8s | %-8s %-8s %-8s %-8s | %-6s | %-10s\n" \
                "HelmRelease" "Namespace" \
                "CPU Req" "CPU Lim" "CPU Avg" "CPU Max" \
                "Mem Req" "Mem Lim" "Mem Avg" "Mem Max" "Mem %" "Discrepancy"
        else
            printf "%-25s %-17s | %-8s %-8s %-8s %-8s | %-8s %-8s %-8s %-8s | %-6s\n" \
                "HelmRelease" "Namespace" \
                "CPU Req" "CPU Lim" "CPU Avg" "CPU Max" \
                "Mem Req" "Mem Lim" "Mem Avg" "Mem Max" "Mem %"
        fi
        echo "----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------"

        # Sort by discrepancy (field 12) if requested, otherwise by mem_lim (field 5)
        if [ "$SORT_BY_DISCREPANCY" = "1" ]; then
            sort_cmd="sort -t'|' -k12 -g -r"
        else
            sort_cmd="sort -t'|' -k5 -n -r"
        fi
        eval "$sort_cmd" "$tmpfile" | while IFS='|' read -r name ns cpu_lim cpu_req mem_lim mem_req cpu_avg mem_avg cpu_max mem_max file mem_discrepancy; do
            # Sanitize numeric values
            cpu_lim=$(echo "$cpu_lim" | grep -E '^[0-9.]+$' || echo "0")
            cpu_req=$(echo "$cpu_req" | grep -E '^[0-9.]+$' || echo "0")
            cpu_avg=$(echo "$cpu_avg" | grep -E '^[0-9.]+$' || echo "0")
            cpu_max=$(echo "$cpu_max" | grep -E '^[0-9.]+$' || echo "0")
            mem_lim=$(echo "$mem_lim" | grep -E '^[0-9.]+$' || echo "0")
            mem_req=$(echo "$mem_req" | grep -E '^[0-9.]+$' || echo "0")
            mem_avg=$(echo "$mem_avg" | grep -E '^[0-9.]+$' || echo "0")
            mem_max=$(echo "$mem_max" | grep -E '^[0-9.]+$' || echo "0")

            # Format CPU values (millicores)
            cpu_req_d=$([ "$cpu_req" = "0" ] && echo "-" || printf "%dm" "$(printf "%.0f" "$cpu_req")")
            cpu_lim_d=$([ "$cpu_lim" = "0" ] && echo "-" || printf "%dm" "$(printf "%.0f" "$cpu_lim")")
            cpu_avg_d=$([ "$cpu_avg" = "0" ] && echo "-" || printf "%dm" "$(printf "%.0f" "$cpu_avg")")
            cpu_max_d=$([ "$cpu_max" = "0" ] && echo "-" || printf "%dm" "$(printf "%.0f" "$cpu_max")")

            # Format memory values (GiB)
            mem_req_d=$([ "$mem_req" = "0" ] && echo "-" || printf "%.2fG" "$mem_req")
            mem_lim_d=$([ "$mem_lim" = "0" ] && echo "-" || printf "%.2fG" "$mem_lim")
            mem_avg_d=$([ "$mem_avg" = "0" ] && echo "-" || printf "%.2fG" "$mem_avg")
            mem_max_d=$([ "$mem_max" = "0" ] && echo "-" || printf "%.2fG" "$mem_max")

            # Calculate memory usage percentage
            if [ "$mem_lim" != "0" ] && [ "$mem_avg" != "0" ]; then
                mem_pct=$(echo "scale=1; $mem_avg * 100 / $mem_lim" | bc -l)
                mem_pct_d=$(printf "%.1f%%" "$mem_pct")
            else
                mem_pct="0"
                mem_pct_d="-"
            fi

            # Color coding based on memory usage
            color=""
            if [ "$mem_lim" != "0" ] && [ "$mem_avg" != "0" ]; then
                if (( $(echo "$mem_pct >= 80" | bc -l) )); then
                    color="$RED"
                elif (( $(echo "$mem_pct >= 60" | bc -l) )); then
                    color="$YELLOW"
                fi
            elif [ "$mem_lim" = "0" ] && [ "$mem_avg" != "0" ]; then
                # No limit set but app is running - warning
                color="$YELLOW"
            fi

            # Format discrepancy for display
            mem_disc_d=$([ "$mem_discrepancy" = "0" ] || [ -z "$mem_discrepancy" ] && echo "-" || printf "%.2fG" "$mem_discrepancy")

            if [ "$SORT_BY_DISCREPANCY" = "1" ]; then
                if [ -n "$color" ]; then
                    printf "${color}%-25s %-17s | %-8s %-8s %-8s %-8s | %-8s %-8s %-8s %-8s | %-6s | %-10s${NC}\n" \
                        "$name" "$ns" "$cpu_req_d" "$cpu_lim_d" "$cpu_avg_d" "$cpu_max_d" "$mem_req_d" "$mem_lim_d" "$mem_avg_d" "$mem_max_d" "$mem_pct_d" "$mem_disc_d"
                else
                    printf "%-25s %-17s | %-8s %-8s %-8s %-8s | %-8s %-8s %-8s %-8s | %-6s | %-10s\n" \
                        "$name" "$ns" "$cpu_req_d" "$cpu_lim_d" "$cpu_avg_d" "$cpu_max_d" "$mem_req_d" "$mem_lim_d" "$mem_avg_d" "$mem_max_d" "$mem_pct_d" "$mem_disc_d"
                fi
            else
                if [ -n "$color" ]; then
                    printf "${color}%-25s %-17s | %-8s %-8s %-8s %-8s | %-8s %-8s %-8s %-8s | %-6s${NC}\n" \
                        "$name" "$ns" "$cpu_req_d" "$cpu_lim_d" "$cpu_avg_d" "$cpu_max_d" "$mem_req_d" "$mem_lim_d" "$mem_avg_d" "$mem_max_d" "$mem_pct_d"
                else
                    printf "%-25s %-17s | %-8s %-8s %-8s %-8s | %-8s %-8s %-8s %-8s | %-6s\n" \
                        "$name" "$ns" "$cpu_req_d" "$cpu_lim_d" "$cpu_avg_d" "$cpu_max_d" "$mem_req_d" "$mem_lim_d" "$mem_avg_d" "$mem_max_d" "$mem_pct_d"
                fi
            fi
        done

        echo "=========================================================================================================================================================================================================="
        echo "SUMMARY & RECOMMENDATIONS"
        echo "=========================================================================================================================================================================================================="

        # Count statistics
        total_count=$(wc -l < "$tmpfile" | tr -d ' ')

        # Count apps with/without configs
        with_mem_limit=$(awk -F'|' '$5 != "0"' "$tmpfile" | wc -l | tr -d ' ')
        with_cpu_limit=$(awk -F'|' '$3 != "0"' "$tmpfile" | wc -l | tr -d ' ')
        with_mem_request=$(awk -F'|' '$6 != "0"' "$tmpfile" | wc -l | tr -d ' ')
        with_cpu_request=$(awk -F'|' '$4 != "0"' "$tmpfile" | wc -l | tr -d ' ')

        # Apps running but no config
        running_no_mem_limit=$(awk -F'|' '$5 == "0" && $8 != "0"' "$tmpfile" | wc -l | tr -d ' ')
        running_no_cpu_limit=$(awk -F'|' '$3 == "0" && $7 != "0"' "$tmpfile" | wc -l | tr -d ' ')

        printf "\n${BLUE}Configuration Coverage:${NC}\n"
        printf "  Total HelmReleases:           %d\n" "$total_count"
        printf "  With CPU limits:              %d (%.1f%%)\n" "$with_cpu_limit" "$(echo "scale=1; $with_cpu_limit * 100 / $total_count" | bc -l)"
        printf "  With CPU requests:            %d (%.1f%%)\n" "$with_cpu_request" "$(echo "scale=1; $with_cpu_request * 100 / $total_count" | bc -l)"
        printf "  With Memory limits:           %d (%.1f%%)\n" "$with_mem_limit" "$(echo "scale=1; $with_mem_limit * 100 / $total_count" | bc -l)"
        printf "  With Memory requests:         %d (%.1f%%)\n" "$with_mem_request" "$(echo "scale=1; $with_mem_request * 100 / $total_count" | bc -l)"

        printf "\n${YELLOW}Missing Limits (Running Apps):${NC}\n"
        printf "  Apps running without CPU limit:    %d\n" "$running_no_cpu_limit"
        printf "  Apps running without Memory limit: %d\n" "$running_no_mem_limit"

        # Show apps that need configuration
        printf "\n${YELLOW}Apps Running Without Limits (Recommended Starting Values):${NC}\n"
        awk -F'|' '$5 == "0" && $8 != "0" {
            cpu_avg = ($7 == "0" || $7 == "") ? 0 : $7
            cpu_max = ($9 == "0" || $9 == "") ? 0 : $9
            mem_avg = ($8 == "0" || $8 == "") ? 0 : $8
            mem_max = ($10 == "0" || $10 == "") ? 0 : $10

            # Recommend 2x max for limits, 1.5x avg for requests
            cpu_lim_rec = int(cpu_max * 2 + 0.5)
            cpu_req_rec = int(cpu_avg * 1.5 + 0.5)
            mem_lim_rec = mem_max * 2
            mem_req_rec = mem_avg * 1.5

            if (mem_avg > 0) {
                printf "  • %-25s | CPU: req=%dm lim=%dm | MEM: req=%.2fGi lim=%.2fGi\n",
                    $1, cpu_req_rec, cpu_lim_rec, mem_req_rec, mem_lim_rec
            }
        }' "$tmpfile" | head -20

        # High usage warnings
        printf "\n${RED}High Memory Usage (>60%% of limit):${NC}\n"
        found_warning=0
        awk -F'|' '$5 != "0" && $5 != "" && $8 != "0" && $8 != "" {
            if ($5 > 0 && $8 > 0) {
                mem_pct = ($8 * 100) / $5
                if (mem_pct >= 60) {
                    printf "  ⚠ %-25s %5.1f%% (%.2f / %.2f GiB) - Consider increasing to %.2f GiB\n",
                        $1, mem_pct, $8, $5, $8 * 1.5
                }
            }
        }' "$tmpfile"
        if [ "$found_warning" = "0" ]; then
            echo "  None found"
        fi

        echo "=========================================================================================================================================================================================================="
        echo -e "${GREEN}Report generated successfully!${NC}"
        echo -e "${CYAN}Samples collected: $SAMPLE_COUNT | Interval: ${SAMPLE_INTERVAL}s${NC}"
        ;;
esac
