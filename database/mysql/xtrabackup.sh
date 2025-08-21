#!/bin/bash
# Description: XTRABACKUP MYSQL BACKUP SCRIPT
# Version: V1.2
# Author: yy
# CREATED DATE: 2021/05/28
# UPDATE DATE: 2025/07/07

source /etc/profile

# 全局变量定义
MYSQL_USER="root"
MYSQL_PASSWORD='password'
MYSQL_CONFIG="/etc/my.cnf"
MYSQL_HOST="localhost"
BACKUP_DIR="/home/backup"
FULL_BAK_DIR="${BACKUP_DIR}/mysql_full_bak"
INCREASE_BAK_DIR="${BACKUP_DIR}/mysql_increase_bak"
# 磁盘检查阈值
DISK_SPACE_THRESHOLD=80
# 副本留存时限
BACKUP_RETENTION_DAYS=7

# 时间变量
YESTERDAY=$(date -d -1day +"%Y-%m-%d")
YEAR=$(date +"%Y")
PREVIOUS_YEAR=$(date -d "1 year ago" "+%Y")
NOWDATE=$(date +"%Y-%m-%d_%H-%M-%S")

PROGPATH="$(dirname "$0")"
[ -f "${PROGPATH}" ] && PROGPATH="."
LOGPATH="${PROGPATH}/log"

# 压缩配置开关,默认开启
ENABLE_COMPRESSION=true
# 压缩算法
COMPRESS_ALGORITHM="zstd"
# 压缩线程
COMPRESS_THREADS=$(($(nproc) / 2))
# 压缩等级,时间换空间
ZSTD_LEVEL=3

# 日志函数
log() {
	local log_type="$1"
	local msg="[$(date '+%Y-%m-%d %H:%M:%S')] ${2}"
	local log_file

	case "${log_type}" in
	"full")
		log_file="${LOGPATH}/xtrabackup_full.log"
		;;
	"incr")
		log_file="${LOGPATH}/xtrabackup_increase.log"
		;;
	esac

	echo -e "${msg}" >>"${log_file}"
}

# 检查磁盘函数
check_disk_space() {
	local backup_dir="$1"
	local log_type="$2"
	local used_space=$(df -P "${backup_dir}" 2>/dev/null | awk 'NR==2 {print $5}' | sed 's/%//')

	if [ -z "${used_space}" ]; then
		log "${log_type}" "无法获取分区空间信息"
		exit 1
	fi

	if [ "${used_space}" -ge "${DISK_SPACE_THRESHOLD}" ]; then
		log "${log_type}" "分区空间不足(已用${used_space}% >= 阈值${DISK_SPACE_THRESHOLD}%)"
		exit 1
	fi

	log "${log_type}" "磁盘空间检查通过(已用${used_space}%)"

	return 0
}

# 检查前置条件函数
check_prerequisites() {
	local log_type=${1}
	local backup_dir=${2}
	local dir_list=(
		"${FULL_BAK_DIR}"
		"${INCREASE_BAK_DIR}"
		"${LOGPATH}"
	)

	for i in "${dir_list[@]}"; do
		if [ ! -d "${i}" ]; then
			log "${log_type}" "创建目录 ${i}"
			mkdir -p "${i}"
		else
			log "${log_type}" "目录 ${i} 已存在"
		fi
	done

	if ! command -v xtrabackup &>/dev/null; then
		log "${log_type}" "未找到 xtrabackup 命令工具"
		exit 1
	fi

	if ! command -v mysql &>/dev/null; then
		log "${log_type}" "未找到 mysql 命令工具"
		exit 1
	fi

	check_disk_space "${backup_dir}" "${log_type}"
}

# 时间转换
format_duration() {
	local seconds=$1
	local hours=$((seconds / 3600))
	local minutes=$(((seconds % 3600) / 60))
	local secs=$((seconds % 60))

	if ((hours > 0)); then
		printf "%d小时%02d分%02d秒" "$hours" "$minutes" "$secs"
	else
		printf "%d分%02d秒" "$minutes" "$secs"
	fi
}

# 清理过期备份
cleanup_old_backups() {
	local log_type="$1"

	[ -n "${FULL_BAK_DIR}" ] && [ -n "${INCREASE_BAK_DIR}" ] || {
		log "${log_type}" "错误: 备份目录未设置"
		return 1
	}

	local cleanup_files=($(find "${FULL_BAK_DIR}" "${INCREASE_BAK_DIR}" \
		-mtime +"${BACKUP_RETENTION_DAYS}" \
		-a \( -name "${YEAR}*" -o -name "${PREVIOUS_YEAR}*" \) 2>/dev/null))

	# 记录将被清理的文件
	if [ ${#cleanup_files[@]} -gt 0 ]; then
		log "${log_type}" "开始清理过期备份(留存时间超过${BACKUP_RETENTION_DAYS}天):\n$(printf " - %s\n" "${cleanup_files[@]}")"

		# 执行清理操作
		find "${FULL_BAK_DIR}" "${INCREASE_BAK_DIR}" \
			-mtime +"${BACKUP_RETENTION_DAYS}" \
			-a \( -name "${YEAR}*" -o -name "${PREVIOUS_YEAR}*" \) \
			-exec rm -rf {} \; 2>/dev/null

		log "${log_type}" "已清理 ${#cleanup_files[@]} 个过期备份"
	else
		log "${log_type}" "未找到需要清理的过期备份"
	fi
}

# 备份函数
run_backup() {
	local log_type="${3}"
	local base_args=(
		"--defaults-file=${MYSQL_CONFIG}"
		"--user=${MYSQL_USER}"
		"--password=${MYSQL_PASSWORD}"
		"--host=${MYSQL_HOST}"
		"--backup"
		"--target-dir=${1}"
	)

	# 增量备份特殊参数
	[ -n "${2}" ] && base_args+=("--incremental-basedir=${2}")

	# 压缩配置
	if ${ENABLE_COMPRESSION}; then
		base_args+=(
			"--compress=${COMPRESS_ALGORITHM}"
			"--compress-threads=${COMPRESS_THREADS}"
		)
		[ "${COMPRESS_ALGORITHM}" = "zstd" ] && base_args+=("--compress-zstd-level=${ZSTD_LEVEL}")
		log "${log_type}" "启用压缩(算法:${COMPRESS_ALGORITHM},线程:${COMPRESS_THREADS},级别:${ZSTD_LEVEL})"
	else
		log "${log_type}" "未启用压缩"
	fi

	# 执行备份
	log "${log_type}" "备份开始..."
	xtrabackup "${base_args[@]}" &>/tmp/xtrabackup-"${YESTERDAY}".log
}

# 全量备份过程
fullvolume_bak() {
	local log_type="full"
	local start_time=$(date +%s)
	local backup_path="${FULL_BAK_DIR}/${NOWDATE}"

	log "${log_type}" ">>> 执行全量备份任务"

	check_prerequisites "${log_type}" "${FULL_BAK_DIR}"

	mysql -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -e 'FLUSH BINARY LOGS;' 2>/dev/null || log "${log_type}" "刷新 binlog 失败,继续备份"

	if run_backup "${backup_path}" "" "${log_type}"; then
		grep "Backup created in directory" /tmp/xtrabackup-"${YESTERDAY}".log >>"${LOGPATH}/xtrabackup.info"
		log "${log_type}" "备份结束,全量备份成功 -> ${backup_path}"
	else
		cp -af /tmp/xtrabackup-"${YESTERDAY}".log "${LOGPATH}/xtrabackup-${YESTERDAY}.log"
		log "${log_type}" "全量备份失败,终止执行! 详见 ${LOGPATH}/xtrabackup-${YESTERDAY}.log"
		return 1
	fi

	cleanup_old_backups "${log_type}"

	local duration=$(($(date +%s) - start_time))
	log "${log_type}" "备份耗时: $(format_duration ${duration})"

	log "${log_type}" "$(du -sh "${FULL_BAK_DIR}/${NOWDATE}" | awk '{print "备份大小:", $1}')"
}

# 增量备份过程
increase_bak() {
	local log_type="incr"
	local start_time=$(date +%s)
	local backup_path="${INCREASE_BAK_DIR}/${NOWDATE}"
	local base_dir=$(tail -n 1 "${LOGPATH}/xtrabackup.info" 2>/dev/null | awk -F\' '{print $2}')

	log "${log_type}" ">>> 执行增量备份任务"

	[ -z "${base_dir}" ] && {
		log "${log_type}" "错误: 无法从 ${LOGPATH}/xtrabackup.info 中获取基准备份目录"
		return 1
	}

	[ ! -d "${base_dir}" ] && {
		log "${log_type}" "错误: 基准备份目录不存在${base_dir}"
		return 1
	}

	check_prerequisites "${log_type}" "${INCREASE_BAK_DIR}"

	if run_backup "${backup_path}" "${base_dir}" "${log_type}"; then
		grep "Backup created in directory" /tmp/xtrabackup-"${YESTERDAY}".log >>"${LOGPATH}/xtrabackup.info"
		log "${log_type}" "备份结束,增量备份成功 -> ${backup_path}"
		log "${log_type}" "基准目录: ${base_dir}"
	else
		cp -af /tmp/xtrabackup-"${YESTERDAY}".log "${LOGPATH}/xtrabackup-${YESTERDAY}.log"
		log "${log_type}" "增量备份失败,终止执行! 详见 ${LOGPATH}/xtrabackup-${YESTERDAY}.log"
		return 1
	fi

	local duration=$(($(date +%s) - start_time))
	log "${log_type}" "备份耗时: $(format_duration ${duration})"

	log "${log_type}" "$(du -sh "${INCREASE_BAK_DIR}/${NOWDATE}" | awk '{print "备份大小:", $1}')"

}

# 主执行函数
case "$1" in
fullvolume)
	fullvolume_bak
	;;
increase)
	increase_bak
	;;
*)
	echo "Usage: $0 {fullvolume|increase}"
	exit 1
	;;
esac
