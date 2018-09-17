#!/bin/bash

source $(pwd)/pipeline.conf

cd $PIPELINE_DIRECTORY
LOG_FILE_LINK=""
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
}

function send_logs_to_slack() {
	sed 's/\x1b\[[^\x1b]*m//g' ${BUILD_DIRECTORY}/${BRANCH_NAME}-${BRANCH_HASH}.log \
		> ${BUILD_DIRECTORY}/${BRANCH_NAME}-${BRANCH_HASH}.tmp
	mv ${BUILD_DIRECTORY}/${BRANCH_NAME}-${BRANCH_HASH}.tmp ${BUILD_DIRECTORY}/${BRANCH_NAME}-${BRANCH_HASH}.log
	SLACK_JSON_FILE="${BUILD_DIRECTORY}/$(date +%s).json"
	slack file upload $BUILD_DIRECTORY/${BRANCH_NAME}-${BRANCH_HASH}.log $SLACK_CHANNEL \
		> ${SLACK_JSON_FILE}
	LOG_FILE_LINK=$(jq -r .file.permalink ${SLACK_JSON_FILE})
	rm ${SLACK_JSON_FILE}
	slack file upload ${BUILD_DIRECTORY}/${BRANCH_NAME}-${BRANCH_HASH}-laravel.log $SLACK_CHANNEL
	sudo rm -rf ${BUILD_DIRECTORY}/${BRANCH_NAME}-${BRANCH_HASH}*
}

function run_pipeline () {

start=`date +%s`
echo "Start cloning and execute branch ${BRANCH_NAME}."
echo "$(date)"
git archive --remote=ssh://git@bitbucket.org/${BITBUCKET_USERNAME}/${REPO_SLUG}.git --format=zip \
	--output="${BRANCH_NAME}-${BRANCH_HASH}.zip" $BRANCH_NAME
unzip -qq ${BRANCH_NAME}-${BRANCH_HASH}.zip -d $BUILD_DIRECTORY/${BRANCH_NAME}-${BRANCH_HASH}
rm ${BRANCH_NAME}-${BRANCH_HASH}.zip
VENDOR_FOLDER=`md5sum $BUILD_DIRECTORY/${BRANCH_NAME}-${BRANCH_HASH}/composer.json | awk '{ print $1 }'`

# If not running previous build
if [ ! -f $BUILD_DIRECTORY/${BRANCH_NAME}-${BRANCH_HASH}.lock ]; then
    docker run --rm -it --name="${BRANCH_NAME}-${BRANCH_HASH}" \
		-v $BUILD_DIRECTORY/${BRANCH_NAME}-${BRANCH_HASH}:/var/www/html \
		-v $BUILD_DIRECTORY/${VENDOR_FOLDER}:/var/www/html/vendor \
		$DOCKER_IMAGE /pipeline.sh > $BUILD_DIRECTORY/${BRANCH_NAME}-${BRANCH_HASH}.log
    cat $BUILD_DIRECTORY/${BRANCH_NAME}-${BRANCH_HASH}/storage/logs/laravel* \
    	>> $BUILD_DIRECTORY/${BRANCH_NAME}-${BRANCH_HASH}-laravel.log
else
    sudo rm -rf $BUILD_DIRECTORY/${BRANCH_NAME}-${BRANCH_HASH}*
fi

end=`date +%s`
runtime=$((end-start))

if [ ! -z "$(sed -e '/^OK/p' $BUILD_DIRECTORY/${BRANCH_NAME}-${BRANCH_HASH}.log)" ]; then
    if ! $IS_UPDATED; then
        slack chat send "*${BRANCH_AUTHOR_FULLNAME}*,\nHooray :tada:\nSuccessful build :champagne:\nTest of \`branch: ${BRANCH_NAME} - hash: ${BRANCH_HASH}\` lasted :timer_clock: $(date -d@$runtime -u +%H:%M:%S)\n:link: : ${PULLREQUEST_WEB_LINK}" $SLACK_CHANNEL
		send_logs_to_slack
        # set status success
        get_access_token
        statuses_build "SUCCESSFUL" $BUILD_KEY $REPO_SLUG $LOG_FILE_LINK "Pipeline Bot"
    fi
else
    slack chat send "*${BRANCH_AUTHOR_FULLNAME}*,\nyour code with errors - :hankey:\nTest of \`branch: ${BRANCH_NAME} - hash: ${BRANCH_HASH}\` lasted :timer_clock: $(date -d@$runtime -u +%H:%M:%S)" $SLACK_CHANNEL
	send_logs_to_slack
    # set status fail
    get_access_token
    statuses_build "FAILED" $BUILD_KEY $REPO_SLUG $LOG_FILE_LINK "Pipeline Bot"
fi

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
		WEBHOOK_JSON_FILE="$BUILD_DIRECTORY/${BRANCH_NAME}-${BRANCH_HASH}.json"
		mv ./webhook.json $BUILD_DIRECTORY/${BRANCH_NAME}-${BRANCH_HASH}.json

		# If decline or merged request
		if [ "$PULLREQUEST_STATE" = "DECLINED" ] || [ "$PULLREQUEST_STATE" = "MERGED" ]; then
			docker stop $(docker ps -a -q --filter="name=${BRANCH_NAME}")
			sudo rm -rf $BUILD_DIRECTORY/${BRANCH_NAME}-${BRANCH_HASH}*
			touch $BUILD_DIRECTORY/${BRANCH_NAME}-${BRANCH_HASH}.lock
			slack chat send "$PULLREQUEST_STATE testing of \`branch: ${BRANCH_NAME} - hash: ${BRANCH_HASH}\`"
			statuses_build "STOPPED" $BUILD_KEY $REPO_SLUG "" "Pipeline Bot"
		fi

		# If update request
		if [ "$PULLREQUEST_STATE" = "OPEN" ]; then
			if [ -d $BUILD_DIRECTORY/${BRANCH_NAME}-${BRANCH_HASH} ] || [ -f $BUILD_DIRECTORY/${BRANCH_NAME}-${BRANCH_HASH}.lock ]; then
				IS_UPDATED=true
				docker stop $(docker ps -a -q --filter="name=${BRANCH_NAME}")
				sudo rm -rf $BUILD_DIRECTORY/${BRANCH_NAME}-${BRANCH_HASH}*
				touch $BUILD_DIRECTORY/${BRANCH_NAME}-${BRANCH_HASH}.lock
				statuses_build "STOPPED" $BUILD_KEY $REPO_SLUG "" "Pipeline Bot"
			else
				# set status build in progress
				get_access_token
				statuses_build "INPROGRESS" $BUILD_KEY $REPO_SLUG "" "Pipeline Bot"
				slack chat send "Started testing of \`branch: ${BRANCH_NAME} - hash: ${BRANCH_HASH}\`
					created by *${BRANCH_AUTHOR_FULLNAME}* at $(date)\n:link: : ${PULLREQUEST_WEB_LINK}" $SLACK_CHANNEL

				run_pipeline
			fi
		fi
	fi
fi
