#!/bin/bash
# Run caching (cache_objects + the L1EG barrel/endcap merge) for several configs in parallel.
#
# Usage: scripts/runCaching.sh [-j MAX_JOBS] [-n] JOB [JOB ...]
#   JOB = <MAJOR>          -> configs/<MAJOR>/caching.yaml
#         <MAJOR>_<MINOR>  -> configs/<MAJOR>/cache_objects/caching_<MINOR>.yaml
#   MAJOR may itself contain underscores (V49nano_AR25); the longest existing config dir wins.
#   -j  number of configs cached at once (default 2: each cache_objects job is memory hungry)
#   -n  dry run: only print what would be run
#
# Lists come from bash brace expansion (leave the braces unquoted), e.g.
#   scripts/runCaching.sh V50nano_{170pre5_SC8mass,170pre5_SC8mass_140PU} V49nano_AR25_151pre4_P2GT
#   scripts/runCaching.sh V49nano_AR25{,_151pre4_P2GT}   # the major config itself and one sub-version
#
# The version passed to merge_arrays and used for the log dir is the top-level key read from the
# YAML (not the job name, as some older files have keys that differ from their file names), and
# the merge runs for every sample in the YAML that has both L1EGbarrel and L1EGendcap cached.
# Logs: logs/<version>_<YYMMDD>/<version>_caching.log

MAX_JOBS=2
DRYRUN=false
while getopts "j:n" opt; do
    case $opt in
        j) MAX_JOBS=$OPTARG ;;
        n) DRYRUN=true ;;
        *) echo "Usage: $0 [-j MAX_JOBS] [-n] JOB [JOB ...]"; exit 1 ;;
    esac
done
shift $((OPTIND - 1))
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 [-j MAX_JOBS] [-n] JOB [JOB ...]"
    exit 1
fi

REVISION=$(date +%y%m%d)

# Job name -> caching config path (empty if not found)
resolve_config() {
    local job=$1 major=$1
    if [[ -d configs/$job ]]; then
        [[ -f configs/$job/caching.yaml ]] && echo configs/$job/caching.yaml
        return
    fi
    while [[ $major == *_* ]]; do
        major=${major%_*}
        if [[ -f configs/$major/cache_objects/caching_${job#${major}_}.yaml ]]; then
            echo configs/$major/cache_objects/caching_${job#${major}_}.yaml
            return
        fi
    done
}

# Prints "<version> <sample>" for every sample in the config
list_samples() {
    python3 -c 'import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
for v in cfg:
    for s in cfg[v]:
        print(v, s)' "$1"
}

cache_one() {
    local cfg=$1
    cache_objects "$cfg" || { echo "cache_objects failed for $cfg"; return 1; }
    list_samples "$cfg" | while read -r version sample; do
        if [[ -f cache/$version/${version}_${sample}_L1EGbarrel.parquet &&
              -f cache/$version/${version}_${sample}_L1EGendcap.parquet ]]; then
            python3 menu_tools/caching/merge_arrays.py --version "$version" --sample "$sample"
        else
            echo "No L1EGbarrel/L1EGendcap cache for $version $sample, skipping L1EG merge"
        fi
    done
}

declare -A SEEN
for job in "$@"; do
    job=${job//[\{\}]/}  # V50nano_{170pre5} (one element) is not brace-expanded by bash
    cfg=$(resolve_config "$job")
    if [[ -z $cfg ]]; then
        echo "No caching config found for '$job', skipping"
        continue
    fi
    versions=$(list_samples "$cfg" | awk '{print $1}' | sort -u | xargs)
    version=${versions%% *}
    if [[ -n ${SEEN[$versions]} ]]; then
        echo "Skipping $cfg: version '$versions' already being cached from ${SEEN[$versions]}"
        continue
    fi
    SEEN[$versions]=$cfg
    log=logs/${version}_${REVISION}/${version}_caching.log

    if $DRYRUN; then
        echo "$job -> $cfg (version: $versions, log: $log)"
        echo "    samples: $(list_samples "$cfg" | awk '{print $2}' | xargs)"
        continue
    fi

    while [[ $(jobs -pr | wc -l) -ge $MAX_JOBS ]]; do
        sleep 3
    done
    mkdir -p "$(dirname "$log")"
    echo "Submitting $job ($cfg) -> $log"
    cache_one "$cfg" &>> "$log" &
done

$DRYRUN && exit 0
echo "All jobs submitted, waiting. Follow with: tail -f logs/*_${REVISION}/*_caching.log"
wait
echo "All caching done"
