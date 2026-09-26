Give me a design plan in .md files for the below architecture design topics and also build a demo project with working skeleton hello world implementation , assume in this git repo, there are many git subprojects under this repo, for example deephaven-server, deephaven-connectors, under deephaven-connectors, there are source-Kafka, source-amps, source-database, connectors-framework; using gradle build, java 21, need to use vault for secrets, use spring vault for database password retrieval, ? The docker images needs CA certificate from enterprise company; Config structure will be : environments (us-dev, us-prod, jp-dev, jp-prod …) / business flows/AppNames(subproject name)/AppInstance ; how to manage CI/CD release cycle in dev, qa, production ; 

how to build docker images for all subprojects with correct image tagging versioning strategy in an enterprise environment , should all subprojects be built with the same versions? 

the versions should not be saved in version.txt , docker images for each subproject should be based on GitHub CI/CD tools or based on git tag to trigger CICD ( goal is to have a hybrid approach: automate versioning using semantic versioning and also allow git tag to trigger docker image tagging, give me docker image tag naming conventions ; how to clean up old unused non-production images ? 

How to manage image tag version in docker compose , should CICD process auto change image tag in docker compose ? 

Should I separate out config to its own repo ? 

How to auto sync config to target machines in different environments, business flows, subprojects/ AppNames, AppInstance ? 

What should be the git repo directory structure for configs for spring boot microservices ? 

Where to put common application yml and where to put override application yml ? 

Should we also leverage environment variables to parameterize application.yml ? 

For example same subproject/AppName, different AppInstance which have source / target end point tcp hosts ports , should we use environment variables or override application yml ? 

For GitHub workflows, how to build a workflow yml for these subprojects , when push to git hub it will trigger build, unit tests, integration test, build images , publish to JFrog ? 

Can I leverage docker / podman to spin up hazelcast, amps, deephaven … etc to do auto integration tests ? 

Can I ssh to a test input/expected output messages repo to get these data and start auto integration tests ? 

How to spin up SQL server for my JDBC tests query database and then publish to AMPS or deephaven ? 

Under each gradle subproject, the directory structure should have : docker, scripts, src, config. 



When writing .md, provide flow diagrams and structural diagram, sequence diagrams , easier to understand the concept 