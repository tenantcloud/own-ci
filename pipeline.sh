#!/bin/bash

# Get data and parse from bitbucket webhook
function get_webhook_data() {
	# As parameter write path to webhook json file
	BRANCH_NAME=$(jq -r '.pullrequest.source.branch.name' $1)
	BRANCH_HASH=$(jq -r '.pullrequest.source.commit.hash' $1)
	BRANCH_AUTHOR=$(jq -r '.pullrequest.author.username' $1)
	BRANCH_AUTHOR_FULLNAME=$(jq -r '.pullrequest.author.display_name' $1)
	COMMIT_API_LINK=$(jq -r '.pullrequest.source.commit.links.self.href' $1)
	PULLREQUEST_STATE=$(jq -r '.pullrequest.state' $1)
	PULLREQUEST_WEB_LINK=$(jq -r '.pullrequest.links.html.href' $1)
	BITBUCKET_KEY=$(jq -r '.repository.project.key' $1)
	REPO_SLUG=$(jq -r '.repository.name' $1)
	BITBUCKET_USERNAME=$(jq -r '.repository.owner.username' $1)
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
		--output="/${BRANCH_NAME}-${BRANCH_HASH}.zip" $BRANCH_NAME
	unzip -qq /${BRANCH_NAME}-${BRANCH_HASH}.zip -d /var/www/html/
	rm /${BRANCH_NAME}-${BRANCH_HASH}.zip
}

# Get bitbucket access token
function get_access_token() {
    curl -X POST \
		https://bitbucket.org/site/oauth2/access_token \
		-H 'Cache-Control: no-cache' \
		-H 'Content-Type: application/x-www-form-urlencoded' \
		-d "client_id=${CLIENT_ID}&grant_type=${GRANT_TYPE}&client_secret=${CLIENT_SECRET}" -o token.json
    
    ACCESS_TOKEN=$(jq -r '.access_token' $(pwd)/token.json)
    rm $(pwd)/token.json
}

# Send file to slack channel
function send_logs_to_slack() {
	SLACK_JSON_FILE="${BUILD_DIRECTORY}/$(date +%s).json"
	slack file upload $BE_LOG_FILE $SLACK_CHANNEL > ${SLACK_JSON_FILE}
	LOG_FILE_LINK=$(jq -r .file.url_private ${SLACK_JSON_FILE})
	rm ${SLACK_JSON_FILE}
	slack file upload $FE_LOG_FILE $SLACK_CHANNEL
    cat $HTTP_DIR/storage/logs/laravel* > /tmp/laravel.log
	slack file upload /tmp/laravel.log $SLACK_CHANNEL
}

source /builds/pipeline.conf
echo $SLACK_CLI_TOKEN > /usr/local/bin/.slack
BUILD_DIRECTORY=/builds/builds
HTTP_DIR=/var/www/html

get_webhook_data /webhook.json

get_repository

VENDOR_FOLDER=`md5sum ${HTTP_DIR}/composer.lock | awk '{ print $1 }'`
NODE_MODULES_FOLDER=`md5sum ${HTTP_DIR}/package-lock.json | awk '{ print $1 }'`

cp -r ${BUILD_DIRECTORY}/${VENDOR_FOLDER} ${HTTP_DIR}/vendor 2>/dev/null
cp -r ${BUILD_DIRECTORY}/${NODE_MODULES_FOLDER} ${HTTP_DIR}/node_modules 2>/dev/null
ln -s ${HTTP_DIR}/node_modules ${HTTP_DIR}/public/
BE_LOG_FILE=${BUILD_DIRECTORY}/${BRANCH_NAME}-${BRANCH_HASH}-BE.log
FE_LOG_FILE=${BUILD_DIRECTORY}/${BRANCH_NAME}-${BRANCH_HASH}-FE.log

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

# back end test
if [ ! -d  ${HTTP_DIR}/vendor ]; then
  composer install --no-interaction --no-progress --prefer-dist
fi
FLDR_SIZE=$(du -s ${HTTP_DIR}/vendor | awk '{print $1}')
if [ "${FLDR_SIZE}" -eq "0" ]; then 
  composer install --no-interaction --no-progress --prefer-dist
fi
php artisan migrate --force
php artisan db:seed
php artisan config:cache
php artisan route:cache
vendor/bin/phpunit -c phpunit.xml tests/Backend 2>&1 | tee ${BE_LOG_FILE}

# front end test
if [ ! -d ${HTTP_DIR}/node_modules ]; then
  nmp i 
fi
FLDR_SIZE=$(du -s ${HTTP_DIR}/node_modules | awk '{print $1}')
if [ ${FLDR_SIZE} -lt 100 ]; then 
  npm i; 
fi
npm run testing
npm run test 2>&1 | sed -r "s:\x1B\[[0-9;]*[mK]::g" > ${FE_LOG_FILE}

[[ ! -z "$(awk '/^OK/' ${BE_LOG_FILE})" ]] && BE_ERROR=true || BE_ERROR=false
[[ -z "$(awk '/^TOTAL:.*FAILED/' ${FE_LOG_FILE})" ]] && FE_ERROR=true || FE_ERROR=false

end=`date +%s`
runtime=$((end-start))

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

# copy vendor 
if [ ! -d "${BUILD_DIRECTORY}/${VENDOR_FOLDER}/" ]; then \
    cp -r ${HTTP_DIR}/vendor/ ${BUILD_DIRECTORY}/${VENDOR_FOLDER}/ ;  fi
# copy node_modules
if [ ! -d "${BUILD_DIRECTORY}/${NODE_MODULES_FOLDER}/" ]; then \
    cp -r ${HTTP_DIR}/node_modules/ ${BUILD_DIRECTORY}/${NODE_MODULES_FOLDER}/ ;  fi