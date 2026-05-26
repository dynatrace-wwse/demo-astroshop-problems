create_token()
{
result=$(curl --request POST 'https://sso.dynatrace.com/sso/oauth2/token' \
--header 'Content-Type: application/x-www-form-urlencoded' \
--data-urlencode 'grant_type=client_credentials' \
--data-urlencode "client_id=$dt_clientid" \
--data-urlencode "client_secret=$dt_clientsecret" \
--data-urlencode 'scope=document:documents:write document:documents:read document:documents:delete document:environment-shares:read document:environment-shares:write document:environment-shares:claim document:environment-shares:delete automation:workflows:read automation:workflows:write automation:workflows:run automation:rules:read automation:rules:write automation:calendars:read automation:calendars:write')
result_dyna=$(echo $result | jq -r '.access_token')
}

get_wf_status()
{
create_token
curl -X 'GET' \
  "$dt_tenant_url/platform/automation/v1/executions/$(echo $id)" \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -H "authorization: Bearer $(echo $result_dyna)" | jq -r '.state'
}

start_event_wf()
{
create_token
res=$(curl -X 'POST' \
  "$dt_tenant_url/platform/automation/v1/workflows/$dt_event_wf/run" \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -H "authorization: Bearer $(echo $result_dyna)" \
  -d '{
      "params": {
        "event_type": "CUSTOM_DEPLOYMENT",
        "PROBLEM": "'$PROBLEM'",
        "Release": "'$RELEASE_VERSION'",
        "Pipelineurl": "'$CI_JOB_URL'",
        "stage": "'$RELEASE_STAGE_STAGING'",
        "Repository": "'$CI_PROJECT_URL'",
        "Release_Version": "'$RELEASE_VERSION'",
        "Application": "'$RELEASE_PRODUCT'",
        "Namespace": "'$RELEASE_STAGE_STAGING'",
        "Build_Version": "build-'$RELEASE_VERSION'"       
      }
  }')

echo $data
echo "Event workflow execution result"
echo $res
id=$(echo $res | jq -r '.id')
echo $id
while [[ $(get_wf_status) == "RUNNING" ]]; do
sleep 10
done

}

start_test_wf()
{
create_token
res=$(curl -X 'POST' \
  "$dt_tenant_url/platform/automation/v1/workflows/$dt_event_wf/run" \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -H "authorization: Bearer $(echo $result_dyna)" \
  -d '{
      "params": {
        "event_type": "START_TEST",
        "PROBLEM": "'$PROBLEM'",
        "Release": "'$RELEASE_VERSION'",
        "Pipelineurl": "'$CI_JOB_URL'",
        "stage": "'$RELEASE_STAGE_STAGING'",
        "Repository": "'$CI_PROJECT_URL'",
        "Release_Version": "'$RELEASE_VERSION'",
        "Application": "'$RELEASE_PRODUCT'",
        "Namespace": "'$RELEASE_STAGE_STAGING'",
        "Build_Version": "build-'$RELEASE_VERSION'"       
      }
   }')
echo "Test workflow execution result"
id=$(echo $res | jq -r '.id')
echo $id
while [[ $(get_wf_status) == "RUNNING" ]]; do
sleep 10
done

}
get_wf_id()
{
create_token
res=$(curl -X 'GET' \
  "$dt_tenant_url/platform/automation/v1/workflows?adminAccess=false" \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -H "authorization: Bearer $(echo $result_dyna)")

dt_event_wf=$(echo $res | jq -r '.results[] | select(.title=="astroshop-cicd-events-smoketest") | .id')
echo "workflow id"
echo $dt_event_wf
}

send_deployment_event()
{
  get_wf_id
  start_event_wf
  start_test_wf
}

send_deployment_event