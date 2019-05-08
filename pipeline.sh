#!/bin/bash

# Get data and parse from bitbucket webhook
function get_webhook_data() {
	# As parameter write path to webhook json file
	BRANCH_NAME=$(jq -r '.pullrequest.source.branch.name' $1)
    BRANCH_NAME_FILTERED=$(echo ${BRANCH_NAME} | sed 's/\//-/')
	BRANCH_HASH=$(jq -r '.pullrequest.source.commit.hash' $1)
	BRANCH_AUTHOR=$(jq -r '.pullrequest.author.username' $1)
	BRANCH_AUTHOR_FULLNAME=$(jq -r '.pullrequest.author.display_name' $1)
	COMMIT_API_LINK=$(jq -r '.pullrequest.source.commit.links.self.href' $1)
	PULLREQUEST_STATE=$(jq -r '.pullrequest.state' $1)
	PULLREQUEST_WEB_LINK=$(jq -r '.pullrequest.links.html.href' $1)
	BITBUCKET_KEY=$(jq -r '.repository.project.key' $1)
	REPO_SLUG=$(jq -r '.repository.name' $1)
	BITBUCKET_USERNAME=$(jq -r '.repository.owner.username' $1)
	DESTINATION_BRANCH_NAME=$(jq -r '.pullrequest.destination.branch.name' $1)
	SELF_API_LINK=$(jq -r '.pullrequest.links.self.href' $1)
	PIPELINE_CHANGED_FILES=""
}

# Set build status on pullrequest commit
function statuses_build() {
    # state: SUCCESSFUL, FAILED, INPROGRESS, STOPPED
    # key: TEN
    # name: tenantcloud.com
    # url: link to report
    # description: Pipeline Bot
    # Example,
    # statuses_build "SUCCESSFUL" "TEN" "tenantcloud.com" "https://tenantcloud.slack.com/report/1" "Pipeline Bot"
    get_access_token
BUILD_DATA=$(cat <<EOF
	{ "state": "$1", "key": "$2", "name": "$3", "url": "$4", "description": "$5" }
EOF
)
curl -X POST \
"${COMMIT_API_LINK}/statuses/build?access_token=${ACCESS_TOKEN}" \
	-H "cache-control: no-cache" \
	-H "content-type: application/json" \
	-d "${BUILD_DATA}"
}

# Download archive to container
function get_repository() {
	git archive --remote=ssh://git@bitbucket.org/${BITBUCKET_USERNAME}/${REPO_SLUG}.git --format=zip \
		--output="/${BRANCH_NAME_FILTERED}-${BRANCH_HASH}.zip" $BRANCH_NAME
	unzip -qq /${BRANCH_NAME_FILTERED}-${BRANCH_HASH}.zip -d /var/www/html/
	rm /${BRANCH_NAME_FILTERED}-${BRANCH_HASH}.zip
}

# Get bitbucket access token
function get_access_token() {
    curl -X POST \
		https://bitbucket.org/site/oauth2/access_token \
		-H 'Cache-Control: no-cache' \
		-H 'Content-Type: application/x-www-form-urlencoded' \
		-d "client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}&grant_type=client_credentials" -o token.json
    
    ACCESS_TOKEN=$(jq -r '.access_token' $(pwd)/token.json)
    rm $(pwd)/token.json
}

function get_diff_stats() {
    curl -L --silent "${SELF_API_LINK}/diffstat?access_token=${ACCESS_TOKEN}" -o diffstat.json

    PIPELINE_CHANGED_FILES=$(jq -r '.values[] .new.path' $(pwd)/diffstat.json | grep '.php$' | sed "s/\"//g")
    rm $(pwd)/diffstat.json
}

# Send file to slack channel
function send_logs_to_slack() {
	SLACK_JSON_FILE="${BUILD_DIRECTORY}/$(date +%s).json"
  cat $BE_LOG_FILE > $LOG_FILE
  perl -pe 's/\x1b\[[0-9;]*[a-zA-Z]//g' $FE_LOG_FILE >> $LOG_FILE
	slack file upload $LOG_FILE $SLACK_CHANNEL > ${SLACK_JSON_FILE}
	LOG_FILE_LINK=$(jq -r .file.url_private ${SLACK_JSON_FILE})
	rm ${SLACK_JSON_FILE}
	# slack file upload $FE_LOG_FILE $SLACK_CHANNEL
    cat $HTTP_DIR/storage/logs/laravel* > /tmp/laravel.log
	slack file upload /tmp/laravel.log $SLACK_CHANNEL
  # To-Do: Add delete all log files
}

function message() {
	echo "$(date '+%Y-%m-%d %H:%M:%S')"
	echo "================================================================================"
	printf "$1\n"
	echo "================================================================================"
}

message "Preparing to start tests"
source /builds/pipeline.conf
echo $SLACK_CLI_TOKEN > /usr/local/bin/.slack
BUILD_DIRECTORY=/builds/builds
HTTP_DIR=/var/www/html

get_webhook_data /webhook.json
JSON_DATA="Branch/HASH:\t${BRANCH_NAME} - ${BRANCH_HASH}\n"
JSON_DATA+="Repository:\t${BITBUCKET_USERNAME}/${REPO_SLUG}\n"
JSON_DATA+="Developer:\t${BRANCH_AUTHOR_FULLNAME}\n"
JSON_DATA+="Pull request:\t${PULLREQUEST_WEB_LINK}"
message "$JSON_DATA"

message "Start cloning repository"
get_repository

VENDOR_FOLDER=`md5sum ${HTTP_DIR}/composer.lock | awk '{ print $1 }'`
VENDOR_FOLDER=${BUILD_DIRECTORY}/${VENDOR_FOLDER}/
NODE_MODULES_FOLDER=`md5sum ${HTTP_DIR}/package-lock.json | awk '{ print $1 }'`
NODE_MODULES_FOLDER=${BUILD_DIRECTORY}/${NODE_MODULES_FOLDER}/

message "Copy vendor and node_modules folders"
cp -r ${VENDOR_FOLDER} ${HTTP_DIR}/vendor 2>/dev/null
cp -r ${NODE_MODULES_FOLDER} ${HTTP_DIR}/node_modules 2>/dev/null
# export PATH=$PATH:${HTTP_DIR}/node_modules/karma/bin/
echo 'export PATH=$PATH:/var/www/html/node_modules/karma/bin/' >> ~/.bashrc
source ~/.bashrc
ln -s ${HTTP_DIR}/node_modules ${HTTP_DIR}/public/
BE_LOG_FILE=${BUILD_DIRECTORY}/${BRANCH_NAME_FILTERED}-${BRANCH_HASH}-BE.log
FE_LOG_FILE=${BUILD_DIRECTORY}/${BRANCH_NAME_FILTERED}-${BRANCH_HASH}-FE.log
LOG_FILE=${BUILD_DIRECTORY}/${BRANCH_NAME_FILTERED}-${BRANCH_HASH}.log

message "Get diff statistics for current branch"
get_diff_stats

message "Start all needed software"
# Start testing 
start=`date +%s`

chown -R mysql:mysql /var/lib/mysql /var/run/mysqld # fix mysql for mac os
cd /var/www/html
cp .env.pipeline .env
service mysql restart
service redis-server restart
service minio restart
mailcatcher
sleep 5
mysql -uroot -proot -e 'create database tenantcloud;'
minio-client config host add s3 http://127.0.0.1:9000 pipeline pipeline
sleep 5 && minio-client mb s3/pipeline

message "Start PHPUnit tests"
# back end test
if [ ! -d  ${HTTP_DIR}/vendor ]; then
  composer global require hirak/prestissimo # parallel download for composer
  composer install --no-interaction --no-progress --prefer-dist
fi
FLDR_SIZE=$(du -s ${HTTP_DIR}/vendor | awk '{print $1}')
if [ "${FLDR_SIZE}" -eq "0" ]; then
  composer global require hirak/prestissimo # parallel download for composer
  composer install --no-interaction --no-progress --prefer-dist
fi
composer dump-autoload -o
php artisan migrate --force
php artisan db:seed
php artisan config:cache
php artisan route:cache

# Run ParaTest if exists or PhpUnit
PARATEST="vendor/bin/paratest"
if [ -f "$PARATEST" ]
then
  # Main DB name
  DB_NAME="tenantcloud"
  # File for dump main DB
  DUMP_FILE="/tmp/tenantcloud_dump.sql"

  echo "Create  dump from DB $DB_NAME"
  mysqldump --single-transaction --routines --events --extended-insert -uroot -proot $DB_NAME > $DUMP_FILE

  # Number of processes (CPU cores * 2)
  PROCESSES=8
  # Create new DBs (skip 1 because already created) and copy data from main DB
  for i in $(seq 2 $PROCESSES); do
    # New DB name
    DB_NAME_NEW="${DB_NAME}_${i}"

    echo "Create DB $DB_NAME_NEW and import data"
    mysql -uroot -proot -e "create database $DB_NAME_NEW"
    mysql -uroot -proot $DB_NAME_NEW < $DUMP_FILE
  done

  # Remove dump file
  rm $DUMP_FILE

  vendor/bin/paratest -p"$PROCESSES" -c phpunit.xml tests/Backend 2>&1 | tee ${BE_LOG_FILE}
else
  vendor/bin/phpunit -c phpunit.xml tests/Backend 2>&1 | tee ${BE_LOG_FILE}
fi

# Check if php-cs-fixer installed
if [ -f 'vendor/bin/php-cs-fixer' ]
then
    echo "Check PHP Coding Standards"
    echo "${PIPELINE_CHANGED_FILES}"
    COMMIT_RANGE="HEAD..${DESTINATION_BRANCH_NAME}"
    if [ -z "${PIPELINE_CHANGED_FILES}" ]; then
    	EXTRA_ARGS=''
    else
    	EXTRA_ARGS=$(printf -- '--path-mode=intersection\n--\n%s' "${PIPELINE_CHANGED_FILES}");
    fi

    vendor/bin/php-cs-fixer fix --config=.php_cs.dist -v --dry-run --show-progress=estimating --using-cache=no ${EXTRA_ARGS}
fi

message "Start FrontEnd tests"
# front end test
if [ -z "$( ls -A ${HTTP_DIR}/node_modules/ )" ]; then
  npm i
fi
npm run testing
npm run test 2>&1 | sed -r "s:\x1B\[[0-9;]*[mK]::g" > ${FE_LOG_FILE}

[[ ! -z "$(awk '/^OK/' ${BE_LOG_FILE})" ]] && BE_ERROR=true || BE_ERROR=false
[[ -z "$(awk '/^npm ERR!/' ${FE_LOG_FILE})" ]] && FE_ERROR=true || FE_ERROR=false

end=`date +%s`
runtime=$((end-start))

message "Send notification to Slack"
get_access_token

if $BE_ERROR && $FE_ERROR ; then
# Build was succesful
  slack chat send "*${BRANCH_AUTHOR_FULLNAME}*, build was successful :white_check_mark:\nTested \`branch: ${BRANCH_NAME} - hash: ${BRANCH_HASH}\` lasted :timer_clock: $(date -d@$runtime -u +%H:%M:%S)\n:link: : ${PULLREQUEST_WEB_LINK}" $SLACK_CHANNEL
  send_logs_to_slack
  statuses_build "SUCCESSFUL" $BITBUCKET_KEY $REPO_SLUG $LOG_FILE_LINK $SLACK_BOT_NAME
else
# Build with error
  TEST_RESULT="BackEnd: "
  if $BE_ERROR; then
    TEST_RESULT+=":white_check_mark:"
  else
    TEST_RESULT+=":no_entry:"
  fi
  TEST_RESULT+=" FrontEnd: "
  if $FE_ERROR; then
    TEST_RESULT+=":white_check_mark:"
  else
    TEST_RESULT+=":no_entry:"
  fi  
  slack chat send "*${BRANCH_AUTHOR_FULLNAME}*, build was unsuccessful ${TEST_RESULT}\nTested \`branch: ${BRANCH_NAME} - hash: ${BRANCH_HASH}\` lasted :timer_clock: $(date -d@$runtime -u +%H:%M:%S)\n:link: : ${PULLREQUEST_WEB_LINK}" $SLACK_CHANNEL
  send_logs_to_slack
  statuses_build "FAILED" $BITBUCKET_KEY $REPO_SLUG $LOG_FILE_LINK $SLACK_BOT_NAME  
fi

message "Copy vendor and node_modules to server if needed"
# copy vendor 
if [ -z "$(ls -A ${VENDOR_FOLDER})" ]; then
  cp -r ${HTTP_DIR}/vendor/ ${VENDOR_FOLDER}
fi
# copy node_modules
if [ -z "$(ls -A ${NODE_MODULES_FOLDER})" ]; then
  cp -r ${HTTP_DIR}/node_modules/ ${NODE_MODULES_FOLDER}
fi