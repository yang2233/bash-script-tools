#!/bin/bash
# Description: Mysql logical backup script
# Version: V1
# Author: yy
# CREATED  DATE: 2021/02/20

[ $(id -u) -ne 0 ] && echo "Please execute this script as root!" && exit 1

source /etc/profile

# Global variables (UPPERCASE)
USER=root
PASSWORD='password'
BACKUP_DIR=/home/backup
YESTERDAY=$(date -d -1day +"%Y-%m-%d")
DAYS=7
DISK_SPACE_THRESHOLD=80

# Log path
PROGPATH=$(dirname "${0}")
LOGPATH="${PROGPATH}/log"
[ -d "${LOGPATH}" ] || mkdir -p "${LOGPATH}"

# Get timestamp in seconds
getTimestamp() {
	local datetime=$(date "+%Y-%m-%d %H:%M:%S")
	local seconds=$(date -d "${datetime}" +%s)
	echo "${seconds}"
}

# check disk space
check_disk_space() {
	local backup_dir="${1}"
	local used_space=$(df -P "${backup_dir}" 2>/dev/null | awk 'NR==2 {print $5}' | sed 's/%//')

	if [ -z "${used_space}" ]; then
		echo "Unable to retrieve partition space information"
		exit 1
	fi

	if [ "${used_space}" -ge "${DISK_SPACE_THRESHOLD}" ]; then
		echo "Insufficient partition space (used ${used_space}% >= threshold ${DISK_SPACE_THRESHOLD}%)"
		exit 1
	fi
	echo "Disk space check passed (used ${used_space}%)"

	return 0
}

Back_Database() {
	echo "------------------------------------------------------------------------------"
	echo "Task execution time: $(date)"
	local adbsize=0
	local startTime=$(getTimestamp)

	[ -d "${BACKUP_DIR}" ] || {
		echo "Create backup directory: ${BACKUP_DIR}"
		mkdir -p "${BACKUP_DIR}"
	}

	check_disk_space "${BACKUP_DIR}"

	# Check if MySQL is installed
	command -v mysql &>/dev/null || {
		echo "MySQL command not found, please install MySQL first!"
		return 1
	}

	# Get the list of databases
	local dbname=($(mysql -u"${USER}" -p"${PASSWORD}" -e 'show databases;' 2>/dev/null | grep -Evw 'Database|information_schema|performance_schema|mysql|test|sys' | tr -d "\r"))

	for i in "${dbname[@]}"; do
		# Check the backup directory
		local backup_subdir="${BACKUP_DIR}/${i}"
		[ -d "${backup_subdir}" ] || {
			echo "Create a directory: ${i}"
			mkdir -p "${backup_subdir}"
		}

		# Start backup
		mysqldump -u"${USER}" -p"${PASSWORD}" --routines --single-transaction --hex-blob --complete-insert --quick -B "${i}" 2>/dev/null >"${backup_subdir}/${i}-${YESTERDAY}.sql"
		local result=$?

		if [ ${result} -eq 0 ]; then
			local dbsize=$(stat -c%s "${backup_subdir}/${i}-${YESTERDAY}.sql")
			adbsize=$((dbsize + adbsize))
			echo "The database (${i}) backup success: ${backup_subdir}/${i}-${YESTERDAY}.sql ($((${dbsize}/1024/1024))MB)"

			# Delete old backups
			echo "Checking for backups older than ${DAYS} days in ${backup_subdir}"
			old_files=($(find "${backup_subdir}" -type f -mtime "+${DAYS}" -name "*.sql" 2>/dev/null))

			if [ ${#old_files[@]} -gt 0 ]; then
				echo "The following old backup files will be deleted:"
				printf ' - %s\n' "${old_files[@]}"

				# Delete old backups
				find "${backup_subdir}" -type f -mtime "+${DAYS}" -name "*.sql" -delete 2>/dev/null
			else
				echo "No old backup files to delete"
			fi
		else
			echo "Backup failed, please check the cause!"
		fi
	done

	local endTime=$(getTimestamp)
	echo "Backup time: $((${endTime} - ${startTime}))s, all backup data size: $((${adbsize} / 1024 / 1024))MB"
	echo "------------------------------------------------------------------------------"
}

Back_Database >>"${LOGPATH}/mysql_bak.log"
