#!/bin/bash
###############################################################################
# Copyright Contributors to the Open Cluster Management project
###############################################################################

set -o nounset
set -o pipefail

echo "SETUP install multicloud-integrations"
kubectl config use-context kind-hub
kubectl apply -f deploy/crds/
kubectl apply -f hack/test/crds/0000_00_authentication.open-cluster-management.io_managedserviceaccounts.yaml
kubectl apply -f deploy/controller/

sleep 120

echo "TEST Propgation controller startup (expecting error)"
POD_NAME=$(kubectl -n open-cluster-management get deploy multicloud-integrations -o yaml  | grep ReplicaSet | grep successful | cut -d'"' -f2)
POD_NAME=$(kubectl -n open-cluster-management get pod | grep $POD_NAME | cut -d' ' -f1)
if kubectl -n open-cluster-management logs $POD_NAME argocd-pull-integration-controller-manager | grep "failed to find CRD applications.argoproj.io"; then
    echo "Propgation controller failed to startup"
else
    echo "Propgation controller startup successfully"
    exit 1
fi

### Setup
echo "SETUP install Argo CD to Managed cluster"
kubectl config use-context kind-cluster1
kubectl create namespace argocd
kubectl apply -n argocd --force -f hack/test/e2e/argo-cd-install.yaml 

echo "SETUP install Argo CD to Hub cluster"
kubectl config use-context kind-hub
kubectl create namespace argocd
kubectl apply -n argocd --force -f hack/test/e2e/argo-cd-install.yaml 
kubectl -n argocd scale deployment/argocd-dex-server --replicas 0
kubectl -n argocd scale deployment/argocd-repo-server --replicas 0
kubectl -n argocd scale deployment/argocd-server --replicas 0
kubectl -n argocd scale deployment/argocd-redis --replicas 0
kubectl -n argocd scale deployment/argocd-notifications-controller --replicas 0
kubectl -n argocd scale statefulset/argocd-application-controller --replicas 0

# enable progressive sync
kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge -p '{"data":{"applicationsetcontroller.enable.progressive.syncs":"true"}}'
kubectl -n argocd rollout restart deployment argocd-applicationset-controller

sleep 60s

echo "TEST Propgation controller startup"
if kubectl -n open-cluster-management logs $POD_NAME argocd-pull-integration-controller-manager | grep "Starting Controller" | grep "Application"; then
    echo "Propgation controller startup successfully"
else
    echo "Propgation controller failed to startup"
    exit 1
fi

echo "SETUP print managed cluster setup"
kubectl config use-context kind-cluster1
kubectl -n argocd get deploy
kubectl -n argocd get statefulset

echo "SETUP print hub setup"
kubectl config use-context kind-hub
kubectl -n argocd get deploy
kubectl -n argocd get statefulset
kubectl -n open-cluster-management get deploy

### GitOpsCluster
echo "TEST GitOpsCluster"
kubectl config use-context kind-hub
# Add test label to cluster1 to test that labels are propagated
kubectl label managedcluster cluster1 test-label=test-value
kubectl apply -f examples/argocd/
sleep 10s
if kubectl -n argocd get gitopsclusters argo-ocm-importer -o yaml | grep successful; then
    echo "GitOpsCluster: status successful"
else
    echo "GitOpsCluster FAILED: status not successful"

    kubectl -n argocd get gitopsclusters argo-ocm-importer -o yaml

    kubectl logs -n open-cluster-management deployment/multicloud-integrations-gitops
    
    exit 1
fi
if [[ "$(kubectl -n argocd get secret -l=test-label=test-value -o jsonpath='{.items[0].metadata.name}')" == "cluster1-cluster-secret" ]]; then
    echo "GitOpsCluster: cluster1-cluster-secret created"
else
    echo "GitOpsCluster FAILED: cluster1-cluster-secret not created"
    exit 1
fi
# Add another test label to cluster1 to test that updated labels are propagated
kubectl label managedcluster cluster1 test-label-2=test-value-2
sleep 20s
if kubectl -n argocd get gitopsclusters argo-ocm-importer -o yaml | grep successful; then
    echo "GitOpsCluster: status successful"
else
    echo "GitOpsCluster FAILED: status not successful"
    exit 1
fi
if [[ "$(kubectl -n argocd get secret -l=test-label-2=test-value-2 -o jsonpath='{.items[0].metadata.name}')" == "cluster1-cluster-secret" ]]; then
    echo "GitOpsCluster: cluster1-cluster-secret updated"
else
    echo "GitOpsCluster FAILED: cluster1-cluster-secret not updated"
    exit 1
fi

### Propagation
echo "TEST Propagation"
kubectl config use-context kind-cluster1
kubectl apply -f e2e/managed/
kubectl config use-context kind-hub
kubectl apply -f e2e/hub/
kubectl apply -f e2e/hub_app/
sleep 120s
if kubectl -n argocd get application cluster1-guestbook-app; then
    echo "Propagation: hub application cluster1-guestbook-app created"
else
    echo "Propagation FAILED: hub application cluster1-guestbook-app not created"
    kubectl -n argocd get applicationset guestbook-app-set -o yaml
    kubectl -n argocd get placementdecision guestbook-app-placement-decision-1 -o yaml
    kubectl -n argocd logs $(kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-applicationset-controller -o jsonpath="{.items[0].metadata.name}")
    exit 1
fi
if kubectl -n cluster1 get manifestwork | grep cluster1-guestbook-app; then
    echo "Propagation: manifestwork created"
else
    echo "Propagation FAILED: manifestwork not created"
    exit 1
fi
if kubectl -n cluster1 get manifestwork -o yaml | grep ed58e4a1479ef2d7fb1a60bc2b7300100f262779; then
    echo "Propagation: manifestwork contains appSet hash"
else
    echo "Propagation FAILED: manifestwork does not contain appSet hash"
    exit 1
fi
if kubectl -n cluster1 get manifestwork -o yaml | grep RollingSync; then
    echo "Propagation: manifestwork contains operation RollingSync"
else
    echo "Propagation FAILED: manifestwork does not contain operation RollingSync"
    exit 1
fi
kubectl config use-context kind-cluster1
if kubectl -n argocd get app cluster1-guestbook-app | grep Synced | grep Healthy; then
    echo "Propagation: managed cluster application cluster1-guestbook-app created, synced and healthy"
else
    echo "Propagation FAILED: managed application cluster1-guestbook-app not created, synced and healthy"
    kubectl -n argocd get app cluster1-guestbook-app -o yaml
    exit 1
fi
if kubectl get namespace guestbook; then
    echo "Propagation: guestbook namespace created"
else
    echo "Propagation FAILED: guestbook namespace not created"
    exit 1
fi
if kubectl -n guestbook get deploy guestbook-ui; then
    echo "Propagation: guestbook-ui deploy created"
else
    echo "Propagation FAILED: guestbook-ui deploy not created"
    exit 1
fi
