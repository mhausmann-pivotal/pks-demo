#!/bin/bash
# Script to create load balancers and firewall rules for K8s created by PKS
# Author: Alex Guedes <aguedes@pivotal.io>

SCRIPT_VERSION="0.2"

usage () {
	echo "Script to create load balancers and firewall rules for K8s created by PKS.";
	echo "Version: ${SCRIPT_VERSION} | Created by Alex Guedes <aguedes@pivotal.io>";
	echo ""
	echo "Available flags (all required):"
	echo "  -h    help"
	echo "  -p    GCP Project ID"
	echo "  -r    GCP Region"
	echo "  -n    GCP Network where your K8s cluster has been deployed"
	echo "  -z    Name of the GCP DNS Zone you created for PKS"
	echo "  -d    Wildcard DNS name for the cluster (without the *.)"
	echo "  -a    DNS entry for K8s cluster API"
	echo "  -f    Prefix for the firewall rules being created"
	echo "  -c    Name of cluster created by the PKS cli"
	echo ""
	echo "Example: ./configure-gcp-pks.sh -p aguedes-project -r europe-west2 -n aguedes-virt-net -z pks-pcf-pw -d cluster1.pks.pcf.pw -a api.cluster1.pks.pcf.pw -f aguedes -c pks-cluster1"
	echo ""
	echo "This script required both gcloud and pks cli to be installed and configured."
	}

while getopts p:r:n:z:d:a:f:c:h option
do
 case "${option}" in
	 p) GCP_PROJECT_ID=${OPTARG};;
	 r) GCP_REGION=${OPTARG};;
	 n) GCP_NETWORK_NAME=${OPTARG};;
	 z) GCP_DNS_ZONE=${OPTARG};;
	 d) DNS_NAME=${OPTARG};;
	 a) API_DNS_NAME=${OPTARG};;
	 f) PREFIX_FW_RULES=${OPTARG};;
	 c) PKS_CLUSTER_NAME=${OPTARG};;
	 h) usage; exit;;
 esac
done

if [ -z "$GCP_PROJECT_ID" ] || [ -z "$GCP_REGION" ] || [ -z "$GCP_NETWORK_NAME" ] || [ -z "$GCP_DNS_ZONE" ] || [ -z "$DNS_NAME" ] || [ -z "$API_DNS_NAME" ] || [ -z "$PREFIX_FW_RULES" ] || [ -z "$PKS_CLUSTER_NAME" ]
	then
		echo "All flags required. Please use -h for help!"
		exit 1
fi

# Create Master Load Balancer, DNS entries and FW rules
echo "Creating Load Balancer for Masters..."
gcloud --project=${GCP_PROJECT_ID} compute addresses create ${PKS_CLUSTER_NAME}-api-ip --region ${GCP_REGION}
gcloud --project=${GCP_PROJECT_ID} compute target-pools create ${PKS_CLUSTER_NAME}-api-lb --region ${GCP_REGION}
gcloud --project=${GCP_PROJECT_ID} compute target-pools add-instances ${PKS_CLUSTER_NAME}-api-lb --instances=`gcloud --project=${GCP_PROJECT_ID} compute instances list --filter="-tags = deployment service-instance-$(pks show-cluster ${PKS_CLUSTER_NAME} | grep UUID | awk '{print $2}') AND -tags = job master" --uri | tr '\n' ','`
gcloud --project=${GCP_PROJECT_ID} compute forwarding-rules create ${PKS_CLUSTER_NAME}-api-forwarding-rule --region ${GCP_REGION} --ports 8443 --address ${PKS_CLUSTER_NAME}-api-ip --target-pool ${PKS_CLUSTER_NAME}-api-lb
echo -e "\nCreating DNS entry for Masters Load Balancer..."
rm -f transaction.yaml
gcloud --project=${GCP_PROJECT_ID} dns record-sets transaction start --zone="${GCP_DNS_ZONE}"
gcloud --project=${GCP_PROJECT_ID} dns record-sets transaction add --zone="${GCP_DNS_ZONE}" --name="${API_DNS_NAME}." --ttl=300 --type=A `gcloud --project=${GCP_PROJECT_ID} compute addresses list --filter="${PKS_CLUSTER_NAME}-api-ip" | awk 'FNR == 2 {print $3}'`
gcloud --project=${GCP_PROJECT_ID} dns record-sets transaction execute --zone="${GCP_DNS_ZONE}"
echo -e "\nCreating firewall rules for Masters (this might fail if rule already exists, but this is fine - it will update instead)..."
if gcloud --project=${GCP_PROJECT_ID} compute firewall-rules create ${PREFIX_FW_RULES}-allow-k8s-api --allow tcp:8443 --network ${GCP_NETWORK_NAME} --source-ranges 0.0.0.0/0 --target-tags service-instance-$(pks show-cluster ${PKS_CLUSTER_NAME} | grep UUID | awk '{print $2}')-master; then echo "Firewall rule created."; else gcloud --project=${GCP_PROJECT_ID} compute firewall-rules update ${PREFIX_FW_RULES}-allow-k8s-api --target-tags `gcloud --project=${GCP_PROJECT_ID} compute firewall-rules describe ${PREFIX_FW_RULES}-allow-k8s-api --format json | jq -r '.targetTags | join(",")'`,service-instance-$(pks show-cluster ${PKS_CLUSTER_NAME} | grep UUID | awk '{print $2}')-master && echo "Creation of firewall rule failed because it already existed. Updated instead."; fi
echo -e "Masters configured!\n"
# Create Wokers Load Balancer, DNS entries and FW rules
echo "Creating Load Balancer for Wokers..."
gcloud --project=${GCP_PROJECT_ID} compute addresses create ${PKS_CLUSTER_NAME}-workers-ip --region ${GCP_REGION}
gcloud --project=${GCP_PROJECT_ID} compute target-pools create ${PKS_CLUSTER_NAME}-workers-lb --region ${GCP_REGION}
gcloud --project=${GCP_PROJECT_ID} compute target-pools add-instances ${PKS_CLUSTER_NAME}-workers-lb --instances=`gcloud --project=${GCP_PROJECT_ID} compute instances list --filter="-tags = deployment service-instance-$(pks show-cluster ${PKS_CLUSTER_NAME} | grep UUID | awk '{print $2}') AND -tags = job worker" --uri | tr '\n' ','`
gcloud --project=${GCP_PROJECT_ID} compute forwarding-rules create ${PKS_CLUSTER_NAME}-workers-forwarding-rule --region ${GCP_REGION} --ports 1-65535 --address ${PKS_CLUSTER_NAME}-workers-ip --target-pool ${PKS_CLUSTER_NAME}-workers-lb
echo -e "\nCreating DNS entry for Wokers Load Balancer..."
rm -f transaction.yaml
gcloud --project=${GCP_PROJECT_ID} dns record-sets transaction start --zone="${GCP_DNS_ZONE}"
gcloud --project=${GCP_PROJECT_ID} dns record-sets transaction add --zone="${GCP_DNS_ZONE}" --name="*.${DNS_NAME}." --ttl=300 --type=A `gcloud --project=${GCP_PROJECT_ID} compute addresses list --filter="${PKS_CLUSTER_NAME}-workers-ip" | awk 'FNR == 2 {print $3}'`
gcloud --project=${GCP_PROJECT_ID} dns record-sets transaction execute --zone="${GCP_DNS_ZONE}"
echo -e "\nCreating firewall rules for Workers (this might fail if rule already exists, but this is fine - it will update instead)..."
if gcloud --project=${GCP_PROJECT_ID} compute firewall-rules create ${PREFIX_FW_RULES}-allow-k8s-workers --allow tcp:1-65535 --network ${GCP_NETWORK_NAME} --source-ranges 0.0.0.0/0 --target-tags service-instance-$(pks show-cluster ${PKS_CLUSTER_NAME} | grep UUID | awk '{print $2}')-worker; then echo "Firewall rule created."; else gcloud --project=${GCP_PROJECT_ID} compute firewall-rules update ${PREFIX_FW_RULES}-allow-k8s-workers --target-tags `gcloud --project=${GCP_PROJECT_ID} compute firewall-rules describe ${PREFIX_FW_RULES}-allow-k8s-workers --format json | jq -r '.targetTags | join(",")'`,service-instance-$(pks show-cluster ${PKS_CLUSTER_NAME} | grep UUID | awk '{print $2}')-worker && echo "Creation of firewall rule failed because it already existed. Updated instead."; fi
echo -e "Wokers configured!\n"
echo "Finished."