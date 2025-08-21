#!/bin/bash
# Function: MySQL User Creation Script
# Version: V1.0
# Author: yy
# CREATED DATE: 2025/08/05

# 加载系统环境变量
source /etc/profile

# 用户host
MYSQL_HOST="%"
# 默认权限
USER_PERMISSIONS="ALL PRIVILEGES"
# 临时文件
OUTPUT_FILE=$(mktemp)

# 数据库映射定义函数
define_account_map() {
	local type=$1
	local version=$2

	declare -gA ACCOUNT_MAP # 全局关联数组

	case "$type" in
	"app_test")
		ACCOUNT_MAP=(
			["u_test_01"]="app_test_db01${version:+_$version}"
			["u_test_02"]="app_test_db02${version:+_$version}"
			["u_test_03"]="app_test_db03${version:+_$version}"
		)
		;;
	"app_prod")
		ACCOUNT_MAP=(
			["u_prod_01"]="app_prod_db01${version:+_$version}"
			["u_prod_02"]="app_prod_db01${version:+_$version}"
			["u_prod_03"]="app_prod_db01${version:+_$version}"
		)
		;;
	# 在这里添加新的类型
	*)
		echo "错误: 不支持的类型 '$type'" >&2
		exit 1
		;;
	esac
}

show_help() {
	echo "用法: bash $0 -u 超管账户 -t 类型 [补充选项]"
	echo "必需参数:"
	echo "  -u  超管账户"
	echo "  -t  项目类型 (app_test|app_prod)"
	echo "补充选项:"
	echo "  -v  目标库版本号 (格式: 3_1 或 31), 已存在的数据库不会重复创建"
	echo "  -c  容器名 (不指定则使用本地MySQL)"
	echo "  -h  显示帮助"
	echo ""
	echo "示例:"
	echo "  # 本地MySQL部署"
	echo "  bash $0 -u root -t app_test -v 3_1"
	echo "  # 容器化部署"
	echo "  bash $0 -u root -t app_test -c mysqld -v 3_1"
	echo "  # 不指定版本号, 则建库或授权时不携带版本号"
	echo "  bash $0 -u root -t app_test"
	exit 0
}

# 解析命令行参数
while getopts "u:t:c:v:h" opt; do
	case $opt in
	u) MYSQL_USER="$OPTARG" ;;
	t) TYPE="$OPTARG" ;;
	c) MYSQL_CONTAINER="$OPTARG" ;;
	v) VERSION="$OPTARG" ;;
	h) show_help ;;
	*)
		echo "无效选项: -$OPTARG" >&2
		exit 1
		;;
	esac
done

# 检查必需参数
if [[ -z "$MYSQL_USER" || -z "$TYPE" ]]; then
	echo "错误: 缺少必需参数!" >&2
	show_help
	exit 1
fi

while true; do
	IFS= read -r -p "请输入超管密码: " -s MYSQL_PASS
	echo
	if [ -z "$MYSQL_PASS" ]; then
		echo "错误: 密码不能为空!" >&2
	else
		break
	fi
done

# 初始化数据库映射
define_account_map "$TYPE" "$VERSION"

# 生成安全随机密码
generate_secure_password() {
	local specials='_@^*'
	local first_char=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c1)
	local upper=$(tr -dc 'A-Z' </dev/urandom | head -c1)
	local lower=$(tr -dc 'a-z' </dev/urandom | head -c1)
	local digit=$(tr -dc '0-9' </dev/urandom | head -c1)
	local special=$(tr -dc "$specials" </dev/urandom | head -c1)
	local rest=$(tr -dc 'A-Za-z0-9_@%^*' </dev/urandom | head -c7)
	echo "${first_char}$(echo "${upper}${lower}${digit}${special}${rest}" | fold -w1 | shuf | tr -d '\n')"
}

# 检测MySQL环境
detect_mysql_env() {
	# 如果未指定容器名，则使用本地MySQL
	if [[ -z "$MYSQL_CONTAINER" ]]; then
		if ! command -v mysql &>/dev/null; then
			echo "错误: MySQL客户端未安装" >&2
			exit 1
		fi
		echo "native"
	else
		# 否则使用docker模式
		if ! command -v docker &>/dev/null; then
			echo "错误: Docker未安装" >&2
			exit 1
		fi
		if ! docker inspect --format '{{.State.Running}}' "$MYSQL_CONTAINER" 2>/dev/null | grep -q 'true'; then
			echo "错误: 容器 $MYSQL_CONTAINER 未运行或不存在" >&2
			exit 1
		fi
		echo "docker"
	fi
}

# 执行MySQL命令
execute_mysql() {
	local env_type=$1
	local query=$2
	case "$env_type" in
	"docker") docker exec -i "$MYSQL_CONTAINER" mysql -u "$MYSQL_USER" -p"$MYSQL_PASS" -Nse "$query" 2>/dev/null ;;
	"native") mysql -u "$MYSQL_USER" -p"$MYSQL_PASS" -Nse "$query" 2>/dev/null ;;
	*)
		echo "错误: 不支持的环境类型 '$env_type'" >&2
		exit 1
		;;
	esac
}

# 检查用户或数据库是否存在
check_exists() {
	local env_type=$1 type=$2 name=$3
	local query
	case "$type" in
	"user") query="SELECT EXISTS(SELECT 1 FROM mysql.user WHERE user='${name}' AND host='${MYSQL_HOST}')" ;;
	"db") query="SELECT EXISTS(SELECT 1 FROM information_schema.schemata WHERE schema_name='${name}')" ;;
	*)
		echo "错误: 不支持的类型 '$type'" >&2
		exit 1
		;;
	esac
	execute_mysql "$env_type" "$query"
}

# 创建数据库
create_database() {
	local env_type=$1
	local dbname=$2

	if [ "$(check_exists "$env_type" "db" "$dbname")" -eq 1 ]; then
		echo "数据库 ${dbname} 已存在，跳过创建"
		return 1
	else
		echo "数据库 ${dbname} 不存在，将创建新数据库"
		if execute_mysql "$env_type" "CREATE DATABASE IF NOT EXISTS \`${dbname}\`"; then
			echo "数据库 ${dbname} 创建成功"
			return 0
		else
			echo "错误: 创建数据库 ${dbname} 失败!" >&2
			return 2
		fi
	fi
}

# 授予权限函数
grant_privileges() {
	local env_type=$1
	local username=$2
	local dbname=$3

	# # 先撤销所有权限
	# execute_mysql "$env_type" "REVOKE ALL PRIVILEGES ON \`${dbname}\`.* FROM '${username}'@'${MYSQL_HOST}';"

	local queries=(
		"GRANT ${USER_PERMISSIONS} ON \`${dbname}\`.* TO '${username}'@'${MYSQL_HOST}';"
		"ALTER USER '${username}'@'${MYSQL_HOST}' PASSWORD EXPIRE NEVER;"
		"FLUSH PRIVILEGES;"
	)

	for query in "${queries[@]}"; do
		if ! execute_mysql "$env_type" "$query"; then
			echo "错误: 执行权限授予失败 - ${query}" >&2
			return 2
		fi
	done

	return 0
}

create_user_and_grant() {
	local env_type=$1
	local username=$2
	local dbname=$3
	local password=$4
	local user_created=0
	local retval=0

	# 检查用户是否存在
	if [ "$(check_exists "$env_type" "user" "$username")" -eq 1 ]; then
		echo "用户 ${username} 已存在, 跳过创建步骤"
		retval=1
	else
		echo "正在创建用户 ${username}..."
		if execute_mysql "$env_type" "CREATE USER '${username}'@'${MYSQL_HOST}' IDENTIFIED BY '${password}';"; then
			echo "用户 ${username} 创建成功"
			user_created=1
		else
			echo "错误: 创建用户 ${username} 失败!" >&2
			return 2
		fi
	fi

	# 执行赋权
	echo "正在为用户 ${username} 授予数据库 ${dbname} 权限..."
	if grant_privileges "$env_type" "$username" "$dbname"; then
		if [ $user_created -eq 1 ]; then
			echo "--> [新建] 用户名: ${username}, 密码: ${password}, 权限数据库: ${dbname}" >>"$OUTPUT_FILE"
		else
			echo "--> [已有] 用户名: ${username}, 密码: [已存在], 权限数据库: ${dbname}" >>"$OUTPUT_FILE"
		fi
	else
		echo "错误: 用户 ${username} 赋权失败!" >&2
		if [ $user_created -eq 1 ]; then
			echo "用户 ${username} 为新建账户, 将删除该用户"
			if ! execute_mysql "$env_type" "DROP USER '${username}'@'${MYSQL_HOST}';"; then
				echo "严重错误: 用户 ${username} 删除失败, 请手动清理!" >&2
			fi
		fi
		return 3
	fi

	return $retval
}

# 主执行函数
main() {
	local env_type=$(detect_mysql_env)
	local new_user_success=0 existing_user_granted=0 create_failed=0 grant_failed=0
	local db_success_count=0 db_skip_count=0 db_fail_count=0

	if ! execute_mysql "$env_type" "SELECT 1;" &>/dev/null; then
		echo "错误: 无法连接到MySQL服务器, 请检查超管账号和密码!" >&2
		exit 1
	fi

	echo "---------------------------------"

	for username in "${!ACCOUNT_MAP[@]}"; do
		local dbname="${ACCOUNT_MAP[$username]}"
		local password=$(generate_secure_password)

		echo "正在处理账户: ${username}, 权限数据库: ${dbname}..."

		# 创建数据库
		create_database "$env_type" "$dbname"
		local db_result=$?

		case $db_result in
		0) ((db_success_count++)) ;;
		1) ((db_skip_count++)) ;;
		2)
			((db_fail_count++))
			echo "数据库 ${dbname} 创建失败, 跳过后续账户 ${username} 的处理"
			continue
			;;
		esac

		# 然后创建用户
		create_user_and_grant "$env_type" "$username" "$dbname" "$password"
		local user_result=$?

		case $user_result in
		0) ((new_user_success++)) ;;
		1) ((existing_user_granted++)) ;;
		2) ((create_failed++)) ;;
		3) ((grant_failed++)) ;;
		esac

		echo "---------------------------------"
	done

	echo "数据库处理结束"
	echo "【执行结果】"
	echo "已创建数据库: ${db_success_count}"
	echo "已存在数据库(跳过创建): ${db_skip_count}"
	echo "创建失败: ${db_fail_count}"
	echo ""
	echo "账户处理结束"
	echo "【执行结果】"
	echo "已创建账户: ${new_user_success}"
	echo "已存在账户(权限更新): ${existing_user_granted}"
	echo "创建失败: ${create_failed}"
	echo "赋权失败: ${grant_failed}"
	echo ""
	echo "【账户密码】"
	cat "$OUTPUT_FILE"

	rm -f "$OUTPUT_FILE"
}

main
