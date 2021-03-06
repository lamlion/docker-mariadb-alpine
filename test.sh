#!/usr/bin/bash
# Test docker image

set -eo pipefail

ENV_FILE=/tmp/mariadb_alpine_test_env

# https://mariadb.com/kb/en/library/mariadb-environment-variables/
export MYSQL_PWD=

echo_success() {
  echo "$(tput setaf 10)$1$(tput sgr0)"
}

echo_error() {
  echo >&2 "$(tput setaf 9)$1$(tput sgr0)"
}

# Execute MySQL statements
execute() {
  if [ -n "$MYSQL_USER" ]; then
    mysql --protocol=tcp --port=33060 --user="$MYSQL_USER" --password="$MYSQL_PASSWORD" -ss -e "$1"
  else
    # two -s to make it output only result
    mysql --protocol=tcp --port=33060 -uroot -ss -e "$1"
  fi
}

container_status() {
  docker inspect --format '{{.State.Status}}' mariadb_alpine_test 2> /dev/null || true
}

start_container() {
  if [ -z "$DOCKER_VOLUME" ]; then
    docker run --detach --name mariadb_alpine_test -p 33060:3306 \
      --env-file="$ENV_FILE" \
      -e MYSQL_ROOT_PASSWORD="$MYSQL_PWD" \
      mariadb-alpine:latest > /dev/null
  else
    docker run --detach --name mariadb_alpine_test -p 33060:3306 \
      --env-file="$ENV_FILE" \
      -e MYSQL_ROOT_PASSWORD="$MYSQL_PWD" \
      -v "${DOCKER_VOLUME}":/var/lib/mysql \
      mariadb-alpine:latest > /dev/null
  fi
}

remove_container() {
  docker stop mariadb_alpine_test &> /dev/null || true
  docker rm mariadb_alpine_test &> /dev/null || true
}

# Check whether container is running
is_container_running() {
  # status: created running paused restarting removing exited dead
  status=$(container_status)
  [ "$status" = 'created' -o "$status" = 'running' ]
}

# Whether mysql is running correctly
is_mysql_running() {
  execute 'SELECT 1' &> /dev/null
}

wait_running() {
  for i in `seq 30 -1 0`; do
    if ! is_container_running; then
      echo_error 'Container failed to start'
      exit 1
    fi

    if is_mysql_running; then
      break
    fi

    sleep 1
  done

  if [ "$i" = 0 ]; then
    echo_error 'Test failed'
    exit 1
  fi
}

check_running() {
  wait_running
  echo_success 'Test successful'
}

# Test MYSQL_ROOT_PASSWORD
test_root_password() {
  export MYSQL_PWD='root'
  echo "Test MYSQL_ROOT_PASSWORD='${MYSQL_PWD}'"
  echo > "$ENV_FILE"
  start_container
  check_running
  remove_container

  # password with special characters
  export MYSQL_PWD='a#F a$b~-'
  echo "Test MYSQL_ROOT_PASSWORD='${MYSQL_PWD}'"
  echo > "$ENV_FILE"
  start_container
  check_running
  remove_container
}

# Test MYSQL_RANDOM_ROOT_PASSWORD
test_random_root_password() {
  unset MYSQL_PWD
  echo "Test MYSQL_RANDOM_ROOT_PASSWORD=yes"
  echo "MYSQL_RANDOM_ROOT_PASSWORD=yes" > "$ENV_FILE"
  start_container
  for i in `seq 30 -1 0`; do
    if ! is_container_running; then
      echo_error 'Container failed to start'
      exit 1
    fi

    password=$(docker logs mariadb_alpine_test 2>&1 | grep -m1 '^GENERATED ROOT PASSWORD:' | cut -d' ' -f4- || true)
    if [ -n "$password" ]; then
      export MYSQL_PWD="$password"
      break
    fi

    sleep 1
  done

  if [ -z "$MYSQL_PWD" ]; then
    echo_error 'Failed to get random root password'
    exit 1
  else
    check_running
    remove_container
  fi
}

# Test MYSQL_ALLOW_EMPTY_PASSWORD
test_empty_root_password() {
  unset MYSQL_PWD
  echo 'Test MYSQL_ALLOW_EMPTY_PASSWORD=yes'
  echo "MYSQL_ALLOW_EMPTY_PASSWORD=yes" > "$ENV_FILE"
  start_container
  check_running
  remove_container
}

# Test MYSQL_ROOT_HOST
test_mysql_root_host() {
  export MYSQL_PWD=mypassword

  # Docker host ip
  local host=$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}')
  echo "Test MYSQL_ROOT_HOST=$host"
  echo "MYSQL_ROOT_HOST=$host" > "$ENV_FILE"
  start_container
  check_running
  remove_container

  # host not owned by current machine
  local host=example.com
  echo "Test MYSQL_ROOT_HOST=$host"
  echo "MYSQL_ROOT_HOST=$host" > "$ENV_FILE"
  start_container
  # Wait for mysqld to startup
  for i in `seq 30 -1 0`; do
    if ! is_container_running; then
      echo_error 'Container failed to start'
      exit 1
    fi

    if docker logs mariadb_alpine_test 2>&1 | grep 'mysqld_safe Starting mysqld daemon' &> /dev/null; then
      sleep 3
      break
    fi
  done
  # Should not be allowed to access the
  result=$(execute 'SELECT 1' 2>&1 || true)
  if [ "$result" = "1" ]; then
    echo_error 'Should not be allowed to connect'
    exit 1
  else
    echo_success 'Test successful'
    remove_container
  fi
}

# Test MYSQL_DATABASE
test_mysql_database() {
  export MYSQL_PWD=mypassword
  local database=blog
  echo "Test MYSQL_DATABASE=$database"
  echo "MYSQL_DATABASE=$database" > "$ENV_FILE"
  start_container
  wait_running
  if execute "SHOW CREATE DATABASE \`$database\`;" &> /dev/null; then
    echo_success 'Test successful'
    remove_container
  else
    echo_error "Database $database not exist"
    exit 1
  fi
}

# Test MYSQL_USER, MYSQL_PASSWORD
test_mysql_user() {
  export MYSQL_PWD=mypassword

  export MYSQL_USER=alice
  export MYSQL_PASSWORD=alice_password
  echo "Test MYSQL_USER=$MYSQL_USER, MYSQL_PASSWORD=$MYSQL_PASSWORD"
  echo -e "MYSQL_USER=$MYSQL_USER\nMYSQL_PASSWORD=$MYSQL_PASSWORD" > "$ENV_FILE"
  start_container
  check_running
  remove_container
  unset MYSQL_USER
  unset MYSQL_PASSWORD
}

# MYSQL_INITDB_SKIP_TZINFO
test_skip_tzinfo() {
  export MYSQL_PWD=mypassword

  echo 'Test MYSQL_INITDB_SKIP_TZINFO='
  echo 'MYSQL_INITDB_SKIP_TZINFO=' > "$ENV_FILE"
  start_container
  wait_running
  local count=$(execute 'SELECT COUNT(*) FROM mysql.time_zone' || true)
  if [ "$count" = "0" ]; then
    echo_error "No timezone records inserted"
    exit 1
  else
    echo_success "Test successful"
    remove_container
  fi

  echo 'Test MYSQL_INITDB_SKIP_TZINFO=yes'
  echo 'MYSQL_INITDB_SKIP_TZINFO=yes' > "$ENV_FILE"
  start_container
  wait_running
  local count=$(execute 'SELECT COUNT(*) FROM mysql.time_zone' || true)
  if [ "$count" != "0" ]; then
    echo_error "Timezone records inserted"
    exit 1
  else
    echo_success "Test successful"
    remove_container
  fi
}


test_volume() {
  export MYSQL_PWD=mypassword
  export DOCKER_VOLUME=$(mktemp -p /tmp -d mariadb_alpine_test_volume.XXXXX)
  echo 'Test volume'
  echo > "$ENV_FILE"
  start_container
  wait_running
  remove_container

  # Use already initialized volume
  start_container
  check_running
  remove_container

  unset DOCKER_VOLUME
}

remove_container

test_root_password
test_empty_root_password
test_random_root_password
test_mysql_root_host
test_mysql_database
test_mysql_user
test_skip_tzinfo
test_volume

echo 'Clean up temp files...'
rm -f  "$ENV_FILE"
sudo rm -rf /tmp/mariadb_alpine_test_volume*
