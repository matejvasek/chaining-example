#!/bin/bash

set -e
set -x

PROJECT=chaining-test-project
DOCKER_REGISTRY=quay.io/mvasek

function wait-for-broker() {
    set +e
    set +x
    while true; do
        echo "waiting for broker..."
        local BROKER_READY=$(oc get broker -o=jsonpath='{.items[?(@.metadata.name == "default")].status.conditions[?(@.type == "Ready")].status}' 2>/dev/null)
        if [[ $BROKER_READY == "True" ]]; then
            break
        fi
        sleep 1
    done
    echo "broker ready"
    set -e
    set -x
}

function wait-for-function() {
    set +e
    set +x
    while true; do
        echo "waiting for function..."
        local FUNC_READY=$(oc get pods -l app.kubernetes.io/name=$1 -o=jsonpath='{.items[0].status.conditions[?(@.type == "Ready")].status}' 2>/dev/null)
        if [[ $FUNC_READY == "True" ]]; then
            break
        fi
        sleep 1
    done
    echo "function ready"
    set -e
    set -x
}

oc adm new-project ${PROJECT}
oc project ${PROJECT}
oc label namespace ${PROJECT} knative-eventing-injection=enabled --overwrite

wait-for-broker

mkdir func-a
cd func-a

appsody init dev.local/node-ce-functions
cat << EOF > index.js
'use strict';

module.exports = async function testFunc(context) {
    console.log('\n\n***func-a has been invoked***\n\n')
    const ret = {
        headers: {
            'ce-specversion': '0.3',
            'ce-type': 'foo',
            'ce-source': 'bar',
            'ce-id': '42',
            'Content-Type': 'application/json'
        },
        message: {
            msg: '***from func-a***'
        }
    };
    return new Promise((resolve, reject) => {
        resolve(ret);
    });
};
EOF

appsody build --tag "${DOCKER_REGISTRY}/func-a:v1" --push --knative

set +e
appsody deploy --knative --no-build -n ${PROJECT}
set -e

wait-for-function func-a

cat << EOF > cronjob-source.yaml
apiVersion: sources.eventing.knative.dev/v1alpha1
kind: CronJobSource
metadata:
  namespace: ${PROJECT}
  name: cronjob-source
spec:
  schedule: "*/1 * * * *"
  data: '{"message": "***from cronjob***"}'
  sink:
    ref:
      apiVersion: eventing.knative.dev/v1alpha1
      kind: Broker
      name: default
EOF
oc apply -f cronjob-source.yaml
# TODO wait for the cronjob pod to start

cat << EOF > trigger.yaml
apiVersion: eventing.knative.dev/v1alpha1
kind: Trigger
metadata:
  name: func-a-trigger
  namespace: ${PROJECT}
spec:
  broker: default
  filter:
    attributes:
      type: dev.knative.cronjob.event
  subscriber:
    ref:
      apiVersion: v1
      kind: Service
      name: func-a
EOF
oc apply -f trigger.yaml

cd ..





mkdir func-b
cd func-b
appsody init dev.local/node-ce-functions
cat << EOF > index.js
'use strict';

module.exports = function (context) {
  console.log('\n\n***func-b has been invoked***\n\n')
  if (!context.cloudevent) {
    throw new Error('No cloud event received');
  }
  console.log("***Cloud event received: " + JSON.stringify(context.cloudevent) + "***");
};
EOF

appsody build --tag "${DOCKER_REGISTRY}/func-b:v1" --push --knative

set +e
appsody deploy --knative --no-build -n ${PROJECT}
set -e

wait-for-function func-b

cat << EOF > trigger.yaml
apiVersion: eventing.knative.dev/v1alpha1
kind: Trigger
metadata:
  name: func-b-trigger
  namespace: ${PROJECT}
spec:
  broker: default
  filter:
    attributes:
      type: foo
      source: bar 
  subscriber:
    ref:
      apiVersion: v1
      kind: Service
      name: func-b
EOF
oc apply -f trigger.yaml

while true; do
    wait-for-function func-b
    oc logs -f $(oc get pods -l app.kubernetes.io/name=func-b -o=jsonpath='{.items[0].metadata.name}') -c user-container
done
