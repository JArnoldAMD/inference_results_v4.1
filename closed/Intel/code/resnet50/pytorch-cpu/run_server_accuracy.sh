#!/bin/bash

CPUS_PER_INSTANCE=2
BATCH_SIZE=4

number_threads=`nproc --all`
if [ $number_threads == 512 ]; then
    number_threads=502
    export number_cores=251
    number_sockets=1
else
    export number_cores=`lscpu -b -p=Core,Socket | grep -v '^#' | sort -u | wc -l`
    number_sockets=`grep physical.id /proc/cpuinfo | sort -u | wc -l`
fi

cpu_per_socket=$((number_cores/number_sockets))
num_instances=$((number_cores/CPUS_PER_INSTANCE))

if [ -z "${DATA_DIR}" ]; then
    echo "Path to dataset not set. Please set it:"
    echo "export DATA_DIR=</path/to/openimages>"
    exit 1
fi

if [ -z "${RN50_START}" ]; then
    echo "Path to resnet50_start model not set. Please set it:"
    export "RN50_START=</path/to/resnet50_start.pth>"
    exit 1
fi

if [ -z "${RN50_END}" ]; then
    echo "Path to resnet50_end model not set. Please set it:"
    export "RN50_END=</path/to/resnet50_end.pth>"
    exit 1
fi

if [ -z "${RN50_FULL}" ]; then
    echo "Path to resnet50_full model not set. Please set it:"
    export "RN50_FULL=</path/to/resnet50_full.pth>"
    exit 1
fi

CONDA_ENV_NAME=rn50-mlperf

export MALLOC_CONF="oversize_threshold:1,background_thread:true,metadata_thp:auto,dirty_decay_ms:9000000000,muzzy_decay_ms:9000000000"

export LD_PRELOAD=${CONDA_PREFIX}/lib/libjemalloc.so

export LD_PRELOAD=${LD_PRELOAD}:${CONDA_PREFIX}/lib/libiomp5.so

KMP_SETTING="KMP_AFFINITY=granularity=fine,compact,1,0"
export KMP_BLOCKTIME=1
export $KMP_SETTING

CUR_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
APP=${CUR_DIR}/build/bin/mlperf_runner

export LD_LIBRARY_PATH=${LD_LIBRARY_PATH}:${CONDA_PREFIX}/lib

if [ -e mlperf_log_accuracy.json ]; then
    rm mlperf_log_accuracy.json
fi


python ./user_config.py
USER_CONF=user.conf

if [ $number_threads == 502 ]; then
    numactl -C 0-41,44-85,86-127,129-170,172-213,214-255 -m 0,1,2,3,4,5 ${APP} --scenario Server  \
        --mode Accuracy  \
        --mlperf_conf ${CUR_DIR}/src/mlperf.conf \
        --user_conf ${USER_CONF} \
        --model_name resnet50 \
        --rn50-part1 ${RN50_START} \
        --rn50-part3 ${RN50_END} \
        --rn50-full-model ${RN50_FULL} \
        --data_path ${DATA_DIR} \
        --num_instance $num_instances \
        --warmup_iters 50 \
        --cpus_per_instance $CPUS_PER_INSTANCE \
        --exclude_cores 42,43,128,171 \
        --total_sample_count 50000 \
        --batch_size $BATCH_SIZE
else
    numactl ${APP} --scenario Server \
    --mode Accuracy \
    --mlperf_conf ${CUR_DIR}/src/mlperf.conf \
    --user_conf ${USER_CONF} \
    --model_name resnet50 \
    --rn50-part1 ${RN50_START} \
    --rn50-part3 ${RN50_END} \
    --rn50-full-model ${RN50_FULL} \
    --data_path ${DATA_DIR} \
    --num_instance $num_instances \
    --warmup_iters 50 \
    --cpus_per_instance $CPUS_PER_INSTANCE \
    --total_sample_count 50000 \
    --batch_size $BATCH_SIZE
fi

echo " ==================================="
echo "         Evaluating Accuracy        "
echo " ==================================="

# Unset env to ensure acc evaluation
unset LD_PRELOAD

if [ -e mlperf_log_accuracy.json ]; then
    python -u ${CONDA_ENV_NAME}/mlperf_inference/vision/classification_and_detection/tools/accuracy-imagenet.py \
        --mlperf-accuracy-file mlperf_log_accuracy.json \
        --imagenet-val-file ${DATA_DIR}/val_map.txt \
        --dtype int32 2>&1|tee server_accuracy.txt
fi
