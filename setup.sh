#!/bin/bash

set -e
set -x

appsody repo add boson https://github.com/openshift-cloud-functions/stacks/releases/latest/download/boson-index.yaml

PROJECT=my-chaining-proj-qwerasdf
PROJECT_DIR=${HOME}/${PROJECT}
DOCKER_REGISTRY=quay.io/mvasek

oc new-project ${PROJECT}
oc project ${PROJECT}
mkdir -p ${PROJECT_DIR}

oc label namespace ${PROJECT} knative-eventing-injection=enabled --overwrite
oc wait --for=condition=ready broker/default

cd ${PROJECT_DIR}
cat << EOF | oc apply -f -
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
oc wait --for=condition=ready cronjobsource/cronjob-source

mkdir ${PROJECT_DIR}/func-a
cd ${PROJECT_DIR}/func-a

appsody init boson/node-ce-functions
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

cat << EOF | oc apply -f -
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
oc wait --for=condition=ready trigger/func-a-trigger

mkdir ${PROJECT_DIR}/func-b
cd ${PROJECT_DIR}/func-b
appsody init boson/quarkus-ce-functions
cat << EOF > src/main/java/org/funqy/demo/LoggingFunction.java
package org.funqy.demo;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.quarkus.funqy.Funq;
import org.jboss.logging.Logger;

import java.util.Map;
import java.util.stream.Collectors;

public class LoggingFunction {

    private static final Logger log = Logger.getLogger("funqy.logging");

    @Funq
    public void logEvent(Map<String,String> data) throws JsonProcessingException {
        log.info("Event data: " + (new ObjectMapper()).writeValueAsString(data));
    }
}

EOF

cat << EOF > src/main/resources/application.properties
quarkus.funqy.export=logEvent
EOF

appsody build --tag "${DOCKER_REGISTRY}/func-b:v1" --push --knative

appsody deploy --knative --no-build -n ${PROJECT}
while ! { oc wait --for=condition=ready ksvc/func-b 2>/dev/null; }; do sleep 1; done

cat << EOF | oc apply -f -
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
oc wait --for=condition=ready trigger/func-b-trigger

while true; do
    oc logs -f $(oc get pods -l app.kubernetes.io/name=func-b -o=jsonpath='{.items[0].metadata.name}') -c user-container
done
