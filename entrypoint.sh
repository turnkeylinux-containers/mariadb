MY=(
    [ROLE]=db
    [RUN_AS]=self

    [MYSQL_ROOT_PASSWORD]="${MYSQL_ROOT_PASSWORD:-}"
    [MYSQL_ROOT_ONETIME_PASSWORD]="${MYSQL_ROOT_ONETIME_PASSWORD:-}"

    [MYSQL_ONETIME_PASSWORD]="${MYSQL_ONETIME_PASSWORD:-}"
    [MYSQL_INITDB_SKIP_TZINFO]="${MYSQL_INITDB_SKIP_TZINFO:-}"

    [DB_NAME]="${DB_NAME:-}"
    [DB_USER]="${DB_USER:-}"
    [DB_PASS]="${DB_PASS:-}"
)

passthrough_unless "mysqld" "$@"

get_config() {
    local -r key="${1}"
    shift

    "$@" --verbose --help 2>/dev/null | sed "s|^${key}[ \t]*\(.*\)$|\1|; t; d"
}

declare -r DATADIR="$(get_config 'datadir' "$@")" SOCKET="$(get_config 'socket' "$@")"
mkdir -p "${DATADIR}"

mysql=( carefully mysql --protocol=socket -uroot -hlocalhost --socket="${SOCKET}" )
mysqladmin=( carefully mysqladmin --protocol=socket -uroot -hlocalhost --socket="${SOCKET}" )

echo 'Initializing database'
carefully mysql_install_db --datadir="$DATADIR" --rpm "${@:2}"
echo 'Database initialized'

pid=
carefully "$@" --skip-networking --socket="${SOCKET}" & pid=$!

poll "${mysql[@]}" -Bsre 'SELECT "Waiting on database to start...";' || fatal "MySQL init process failed"

if [[ -z "${MY[MYSQL_INITDB_SKIP_TZINFO]}" ]]; then
    # sed is for https://bugs.mysql.com/bug.php?id=20545
    mysql_tzinfo_to_sql /usr/share/zoneinfo \
    | sed 's/Local time zone must be set--see zic manual page/FCTY/' \
    | "${mysql[@]}" mysql
fi

random_if_empty MYSQL_ROOT_PASSWORD

{
    cat <<<"
        -- What's done here shouldn't be replicated or
        --  products like mysql-fabric won't work
        SET @@SESSION.SQL_LOG_BIN=0;
        DELETE FROM mysql.user;
        FLUSH PRIVILEGES;
        CREATE USER 'root'@'%';
        GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION;
        DROP DATABASE IF EXISTS test;
    "

    if [[ -n "${MY[MYSQL_ROOT_PASSWORD]}" ]]; then
        echo "SET PASSWORD FOR 'root'@'%'=PASSWORD('${MY[MYSQL_ROOT_PASSWORD]}');"
    fi

    if [[ -n "${MY[DB_NAME]}" ]]; then
        echo "CREATE DATABASE IF NOT EXISTS \`${MY[DB_NAME]}\`;"
    fi

    if [[ -n "${MY[DB_USER]}" ]]; then
        if [[ -z "${MY[DB_PASS]}" ]]; then
            MY[DB_PASS]="$(secret create DB_PASS)"
        fi
        echo "CREATE USER '${MY[DB_USER]}'@'127.0.0.1' IDENTIFIED BY '${MY[DB_PASS]}';"
        if [[ -n "${MY[DB_NAME]}" ]]; then
            echo "GRANT ALL ON \`${MY[DB_NAME]}\`.* TO '${MY[DB_USER]}'@'127.0.0.1';"
        fi
    fi

    if [[ -n "${MY[MYSQL_ROOT_ONETIME_PASSWORD]}" ]]; then
        echo "ALTER USER 'root'@'%' PASSWORD EXPIRE;"
    fi

    if [[ -n "${MY[MYSQL_ONETIME_PASSWORD]}" ]]; then
        echo "ALTER USER '${MY[DB_USER]}'@'%' PASSWORD EXPIRE;"
    fi
} | "${mysql[@]}"

mysql+=( -p"${MY[MYSQL_ROOT_PASSWORD]}" )
mysqladmin+=( -p"${MY[MYSQL_ROOT_PASSWORD]}" )

if [[ -n "${MY[DB_NAME]}" ]]; then
    mysql+=( "${MY[DB_NAME]}" )
fi

shopt -s nullglob
for f in ${OUR[INITDBS]}/*; do
    case "${f}" in
        *.sql)
            log "running $f";
            "${mysql[@]}" < "${f}"
            ;;
        *)
            log "ignoring $f"
            ;;
    esac
done

"${mysqladmin[@]}" -u root shutdown
wait "${pid}" && log "MariaDB init process done." || fatal "MariaDB init process failed with code $?."

if am_root; then
    chown -R mariadb:mariadb "${DATADIR}"
fi

run "$@"
