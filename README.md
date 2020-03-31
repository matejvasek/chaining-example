## Function chaining example for [node-ce-functions](https://github.com/openshift-cloud-functions/node-ce-functions)

This is heavily based on: https://github.com/danbev/faas-js-runtime-image/tree/knative-example/example

The purpose of this example is to demonstrate connection between two cloud functions (based on [node-ce-functions](https://github.com/openshift-cloud-functions/node-ce-functions))  using cloud events.

Before we start we need:
* installed [appsody CLI](https://appsody.dev/)
* installed [node-ce-functions](https://github.com/openshift-cloud-functions/node-ce-functions) appsody stack
* running OpenShift and being logged into it by `oc`
* installed Knative Serving & Eventing on the OpenShift cluster
* running `Docker` and being logged into a registry where you can push `func-a` and `func-b` images 

We are going to create two functions `func-a` and `func-b`. The `func-a` function will listen for a `cronjob` events and then it will send an event for the `func-b` function. The `func-b` function will be logging incoming events.

#### Project setup

```shell
appsody repo add boson https://github.com/openshift-cloud-functions/stacks/releases/latest/download/boson-index.yaml

PROJECT=my-chaining-proj
PROJECT_DIR=${HOME}/${PROJECT}
DOCKER_REGISTRY=quay.io/mvasek

oc new-project ${PROJECT}
oc project ${PROJECT}
mkdir -p ${PROJECT_DIR}
cd ${PROJECT_DIR}
```

#### Broker setup

```shell
oc label namespace ${PROJECT} knative-eventing-injection=enabled --overwrite
oc wait --for=condition=ready broker/default
```
This creates default broker for the project.
Wait until the default broker is ready.

#### CronJob setup
```shell
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
```
This creates CronJob. The job sends event every minute.
Wait until the job is running.

#### func-a setup
```shell
mkdir -p ${PROJECT_DIR}/func-a
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

appsody deploy --knative --no-build -n ${PROJECT}
oc wait --for=condition=ready ksvc/func-a
```
This creates the `func-a` function.
Wait until the function (Knative Service) is ready.

```shell
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
```
This sets up a trigger. The trigger makes the `func-a` function receiveing `CronJob` events.
Wait until the trigger is ready.

#### func-b setup
```shell
mkdir -p ${PROJECT_DIR}/func-b
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
oc wait --for=condition=ready ksvc/func-b
```
This creates the `func-b` function. Wait until the function (Knative Service) is ready.

```shell
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
```
This sets up a trigger. The trigger makes the `func-b` function receiving events from the `func-a` function.
Wait until the trigger is ready.

#### Observe the `func-b` function logs

```shell
oc logs -f $(oc get pods -l app.kubernetes.io/name=func-b -o=jsonpath='{.items[0].metadata.name}') -c user-container 
```
The command above shows logs of the function.
It should contain `***func-b has been invoked***` every minute.

#### Event emulation

If you don't want to wait one minute for event to be sent you can emulate it.

Forward port from the broker to the localhost:
```shell
oc port-forward svc/default-broker 8080:80
```

Emulate an event by `curl`:
```shell
curl http://localhost:8080 \
    -X POST \
    -H "Ce-Id: 42" \
    -H "Ce-specversion: 0.3" \
    -H "Ce-Type: dev.knative.cronjob.event" \
    -H "Ce-Source: bar" \
    -H "Content-Type: application/json" \
    -d '{"msg":"Message to js-example-service"}' \
    -v

```
