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
oc get broker -w
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
oc get pod -l sources.eventing.knative.dev/cronJobSource=cronjob-source -w
```
This creates CronJob. The job sends event every minute.
Wait until the job is running.

#### func-a setup
```shell
mkdir -p ${PROJECT_DIR}/func-a
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

appsody deploy --knative --no-build -n ${PROJECT}
oc get ksvc -w
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
oc get trigger -w
```
This sets up a trigger. The trigger makes the `func-a` function receiveing `CronJob` events.
Wait until the trigger is ready.

#### func-b setup
```shell
mkdir -p ${PROJECT_DIR}/func-b
cd ${PROJECT_DIR}/func-b

appsody init dev.local/node-ce-functions
cat << EOF > index.js
'use strict';

module.exports = function (context) {
  console.log('\n\n***func-b has been invoked***\n\n')
  if (!context.cloudevent) {
    throw new Error('No cloud event received');
  }
  console.log("\n***Cloud event received: " + JSON.stringify(context.cloudevent) + "***\n\n");
};
EOF

appsody build --tag "${DOCKER_REGISTRY}/func-b:v1" --push --knative

appsody deploy --knative --no-build -n ${PROJECT}
oc get ksvc -w
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
oc get trigger -w
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
oc port-forward $(oc get pod -l eventing.knative.dev/broker=default,eventing.knative.dev/brokerRole=ingress -o=jsonpath='{.items[].metadata.name}') 8080:8080
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
