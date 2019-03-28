#!/bin/bash

source $(pwd)/pipeline.conf

cd $PIPELINE_DIRECTORY
LOG_FILE_LINK="https://bitbucket.org/${BITBUCKET_USERNAME}/${REPO_SLUG}"
IS_UPDATED=false
BRANCH_HASH=$(date +%s)

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

function send_logs_to_slack() {
	SLACK_JSON_FILE="${BUILD_DIRECTORY}/$(date +%s).json"
	slack file upload $BUILD_DIRECTORY/${BRANCH_NAME}-${BRANCH_HASH}.log $SLACK_CHANNEL \
		> ${SLACK_JSON_FILE}
	LOG_FILE_LINK=$(jq -r .file.url_private ${SLACK_JSON_FILE})
	rm ${SLACK_JSON_FILE}
	slack file upload ${BUILD_DIRECTORY}/${BRANCH_NAME}-${BRANCH_HASH}-laravel.log $SLACK_CHANNEL
	sudo rm -rf ${BUILD_DIRECTORY}/${BRANCH_NAME}-${BRANCH_HASH}*
}

function start_container() {
    docker run --rm -it --name="${REPO_SLUG}-$(echo ${BRANCH_NAME} | sed 's/\//-/')-${BRANCH_HASH}" \
		-v $(echo $HOME)/.ssh:/root/.ssh \
		-v $(pwd):/builds \
		-v ${WEBHOOK_JSON_FILE}:/webhook.json \
		$DOCKER_IMAGE /builds/pipeline.sh

	rm ${WEBHOOK_JSON_FILE}

    # cat ${BUILD_DIRECTORY}/${BRANCH_NAME}-${BRANCH_HASH}/storage/logs/laravel* \
    # 	>> ${BUILD_DIRECTORY}/${BRANCH_NAME}-${BRANCH_HASH}-laravel.log
	# sed 's/\x1b\[[^\x1b]*m//g' ${BUILD_DIRECTORY}/${BRANCH_NAME}-${BRANCH_HASH}.log \
	# 	> ${BUILD_DIRECTORY}/${BRANCH_NAME}-${BRANCH_HASH}.tmp
	# mv ${BUILD_DIRECTORY}/${BRANCH_NAME}-${BRANCH_HASH}.tmp ${BUILD_DIRECTORY}/${BRANCH_NAME}-${BRANCH_HASH}.log
}

function get_repository() {
	git archive --remote=ssh://git@bitbucket.org/${BITBUCKET_USERNAME}/${REPO_SLUG}.git --format=zip \
		--output="${BRANCH_NAME}-${BRANCH_HASH}.zip" $BRANCH_NAME
	sudo rm -rf ${BUILD_DIRECTORY}/${BRANCH_NAME}-*
	unzip -qq ${BRANCH_NAME}-${BRANCH_HASH}.zip -d ${BUILD_DIRECTORY}/${BRANCH_NAME}-${BRANCH_HASH}
	rm ${BRANCH_NAME}-${BRANCH_HASH}.zip
}

function report_to_slack() {
	LOG_FILE_DOCKER_RUN="${BUILD_DIRECTORY}/${BRANCH_NAME}-${BRANCH_HASH}.log"
	LOCK_FILE_DOCKER_RUN="${BUILD_DIRECTORY}/${BRANCH_NAME}-${BRANCH_HASH}.lock"
	if [ ! -f ${LOCK_FILE_DOCKER_RUN} ]; then
		if [ ! -z "$(awk '/^OK/' $LOG_FILE_DOCKER_RUN)" ]; then
			slack chat send "*${BRANCH_AUTHOR_FULLNAME}*,\nHooray :tada:\nSuccessful build :champagne:\nTest of \`branch: ${BRANCH_NAME} - hash: ${BRANCH_HASH}\` lasted :timer_clock: $(date -d@$runtime -u +%H:%M:%S)\n:link: : ${PULLREQUEST_WEB_LINK}" $SLACK_CHANNEL
			send_logs_to_slack
			# set status success
			get_access_token
			statuses_build "SUCCESSFUL" $BITBUCKET_KEY $REPO_SLUG $LOG_FILE_LINK $SLACK_BOT_NAME
		else
			slack chat send "*${BRANCH_AUTHOR_FULLNAME}*,\nyour code with errors - :hankey:\nTest of \`branch: ${BRANCH_NAME} - hash: ${BRANCH_HASH}\` lasted :timer_clock: $(date -d@$runtime -u +%H:%M:%S)" $SLACK_CHANNEL
			send_logs_to_slack
			# set status fail
			get_access_token
			statuses_build "FAILED" $BITBUCKET_KEY $REPO_SLUG $LOG_FILE_LINK $SLACK_BOT_NAME
		fi
	fi
	rm $LOCK_FILE_DOCKER_RUN
}

function check_cache_folder() {
	VENDOR_FOLDER=`md5sum ${BUILD_DIRECTORY}/${BRANCH_NAME}-${BRANCH_HASH}/composer.lock | awk '{ print $1 }'`
	NODE_MODULES_FOLDER=`md5sum ${BUILD_DIRECTORY}/${BRANCH_NAME}-${BRANCH_HASH}/package-lock.json | awk '{ print $1 }'`
}

function run_pipeline () {

# start=`date +%s`
# echo "Start cloning and execute branch ${BRANCH_NAME}."
# echo "$(date)"

# get_repository

# check_cache_folder

# # If not running previous build
# if [ ! -f ${BUILD_DIRECTORY}/${BRANCH_NAME}-${BRANCH_HASH}.lock ]; then
# 	start_container
# else
#     sudo rm -rf $BUILD_DIRECTORY/${BRANCH_NAME}-*
# fi

start_container

# end=`date +%s`
# runtime=$((end-start))

# report_to_slack

}

if [ "$1" != "" ]; then
BRANCH_NAME=$1
# PULLREQUEST_STATE="OPEN"
# TODO:
# get json data for this repository and run testing
else
# Check if getting correct JSON file
	if jq -e . >/dev/null 2>&1 <<< $(cat ./webhook.json); then
		get_webhook_data "./webhook.json"
		WEBHOOK_JSON_FILE="${BUILD_DIRECTORY}/$(echo ${BRANCH_NAME} | sed 's/\//-/')-${BRANCH_HASH}.json"
		mv ./webhook.json ${WEBHOOK_JSON_FILE}

		# If decline or merged request
		if [ "$PULLREQUEST_STATE" = "DECLINED" ] || [ "$PULLREQUEST_STATE" = "MERGED" ]; then
			docker stop $(docker ps -a -q --filter="name=${REPO_SLUG}-${BRANCH_NAME}-${BRANCH_HASH}")
			# docker stop $(docker ps -a -q --filter="name=${BRANCH_NAME}")
			sudo rm -rf ${BUILD_DIRECTORY}/${BRANCH_NAME}-${BRANCH_HASH}*
			# touch ${BUILD_DIRECTORY}/${BRANCH_NAME}-${BRANCH_HASH}.lock
			slack chat send "$PULLREQUEST_STATE testing of \`branch: ${BRANCH_NAME} - hash: ${BRANCH_HASH}\`"
			statuses_build "STOPPED" $BITBUCKET_KEY $REPO_SLUG $LOG_FILE_LINK $SLACK_BOT_NAME
		fi

		# If update request
		if [ "$PULLREQUEST_STATE" = "OPEN" ]; then
			if [ ! -z $(find ${BUILD_DIRECTORY} -maxdepth 1 -mindepth 1 -type d -name "${BRANCH_NAME}*" | sed -e 's/^.*\/builds\///') ] || [ -f $BUILD_DIRECTORY/${BRANCH_NAME}-${BRANCH_HASH}.lock ]; then
				IS_UPDATED=true
				docker stop $(docker ps -a -q --filter="name=${REPO_SLUG}-${BRANCH_NAME}-${BRANCH_HASH}")
				# docker stop $(docker ps -a -q --filter="name=${BRANCH_NAME}")
				sudo rm -rf ${BUILD_DIRECTORY}/${BRANCH_NAME}-${BRANCH_HASH}*
				# touch ${BUILD_DIRECTORY}/${BRANCH_NAME}-${BRANCH_HASH}.lock
				statuses_build "STOPPED" $BITBUCKET_KEY $REPO_SLUG $LOG_FILE_LINK $SLACK_BOT_NAME
				slack chat send "Stopped testing of \`branch: ${BRANCH_NAME} - hash: ${BRANCH_HASH}\` created by *${BRANCH_AUTHOR_FULLNAME}*" $SLACK_CHANNEL
				slack chat send "Started again of \`branch: ${BRANCH_NAME} - hash: ${BRANCH_HASH}\` created by *${BRANCH_AUTHOR_FULLNAME}* at $(date)\n:link: : ${PULLREQUEST_WEB_LINK}" $SLACK_CHANNEL
				# start=`date +%s`
				# get_repository
				# check_cache_folder
				get_access_token
				statuses_build "INPROGRESS" $BITBUCKET_KEY $REPO_SLUG $LOG_FILE_LINK $SLACK_BOT_NAME
				# start_container
				# end=`date +%s`
				# runtime=$((end-start))
				# report_to_slack
			else
				# set status build in progress
				get_access_token
				statuses_build "INPROGRESS" $BITBUCKET_KEY $REPO_SLUG $LOG_FILE_LINK $SLACK_BOT_NAME
				slack chat send "Started testing of \`branch: ${BRANCH_NAME} - hash: ${BRANCH_HASH}\` created by *${BRANCH_AUTHOR_FULLNAME}* at $(date)\n:link: : ${PULLREQUEST_WEB_LINK}" $SLACK_CHANNEL

				run_pipeline
			fi
		fi
	fi
fi

# rm ${BUILD_DIRECTORY}/${BRANCH_NAME}-${BRANCH_HASH}.lock