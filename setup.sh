#!/bin/bash

set -e
set -x

PROJECT=my-chaining-proj-asdfqwerwerasdf
PROJECT_DIR=${HOME}/${PROJECT}
DOCKER_REGISTRY=quay.io/mvasek

oc new-project ${PROJECT}
oc project ${PROJECT}
mkdir -p ${PROJECT_DIR}

oc label namespace ${PROJECT} knative-eventing-injection=enabled --overwrite
oc wait --for=condition=ready broker/default

cd ${PROJECT_DIR}
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
oc wait --for=condition=ready cronjobsource/cronjob-source

mkdir ${PROJECT_DIR}/func-a
cd ${PROJECT_DIR}/func-a

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
while ! { oc wait --for=condition=ready ksvc/func-a 2>/dev/null; }; do sleep 1; done

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
oc wait --for=condition=ready trigger/func-a-trigger

mkdir ${PROJECT_DIR}/func-b
cd ${PROJECT_DIR}/func-b
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

appsody deploy --knative --no-build -n ${PROJECT}
while ! { oc wait --for=condition=ready ksvc/func-b 2>/dev/null; }; do sleep 1; done

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
oc wait --for=condition=ready trigger/func-b-trigger

while true; do
    oc logs -f $(oc get pods -l app.kubernetes.io/name=func-b -o=jsonpath='{.items[0].metadata.name}') -c user-container
done
