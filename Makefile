#########################
### Variables Section ###
#########################

.ONESHELL:
# PostgreSQL OPERATOR Variables
PostgreSQL_OPERATOR_NAMESPACE := postgres
PostgreSQL_OPERATOR_VERSION := 1.10.1
POSTGRES_OPERATOR_CHECK = $(shell kubectl get pods -A -l app.kubernetes.io/name=postgres-operator)

# PowerDNS Variables 
POSTGRES_DB_SECRET = $(shell kubectl get secret pdns.pdns-postgres-db.credentials.postgresql.acid.zalan.do -n $(PDNS_NAMESPACE) -o json | jq -r '.data.password')
DOMAIN := example.com
PUBLIC_RESOLVER := 8.8.8.8
ENABLE_RECURSOR_DEBUG_LOGS := false
PDNS_NAMESPACE := pdns

.PHONY: install-postgresql-operator

###########################
### Deployment Section ####
###########################
all: prep install-postgresql-operator wait_for_postgres_operator postgres-db-install wait_for_postgresql postgres-db-init wait_for_db_init pdns-auth-install pdns-recursor-install

ifeq ($(strip $(ENABLE_RECURSOR_DEBUG_LOGS)),true)
  PDNS_RECURSOR_QUIET := false
  PDNS_RECURSOR_LOGLEVEL := 7
else
  PDNS_RECURSOR_QUIET := true
  PDNS_RECURSOR_LOGLEVEL := 6
endif

prep:
# PostgreSQL Operator
	kubectl create namespace $(PostgreSQL_OPERATOR_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	helm repo add postgres-operator-charts https://opensource.zalando.com/postgres-operator/charts/postgres-operator
	
# PowerDNS Namespace
	kubectl create namespace $(PDNS_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -

install-postgresql-operator:
ifneq ($(strip $(POSTGRES_OPERATOR_CHECK)),)
	$(info Postgres Operator is already installed. Nothing to do here.)
else
	helm upgrade --install postgres-operator \
	--set configKubernetes.enable_pod_antiaffinity=true \
	--set configKubernetes.enable_readiness_probe=true \
	--namespace $(PostgreSQL_OPERATOR_NAMESPACE) \
	--version=$(PostgreSQL_OPERATOR_VERSION) \
	postgres-operator-charts/postgres-operator
endif

wait_for_postgres_operator:
	@while true; do \
        status=$$(kubectl -n $(PostgreSQL_OPERATOR_NAMESPACE) get pods -l app.kubernetes.io/name=postgres-operator -o json | jq -r '.items[].status.phase'); \
        if [ "$$status" = "Running" ]; then \
            echo "Postgres Operator is ready."; \
            break; \
        else \
            echo "Postgres Operator is not ready yet. Waiting..."; \
            sleep 10; \
        fi; \
    done

postgres-db-install:
	kubectl -n $(PDNS_NAMESPACE) apply -f ./postgres-db/postgres-db.yaml

wait_for_postgresql:
	@while true; do \
        status=$$(kubectl get postgresql pdns-postgres-db -o json | jq -r '.status.PostgresClusterStatus'); \
        if [ "$$status" = "Running" ]; then \
            echo "PostgreSQL cluster is now Running."; \
            break; \
        else \
            echo "PostgreSQL cluster is still not ready. Waiting..."; \
            sleep 10; \
        fi; \
    done

postgres-db-init:
	kubectl -n $(PDNS_NAMESPACE) apply -f ./postgres-db/postgres-init.yaml

wait_for_db_init:
	@while true; do \
        status=$$(kubectl -n $(PDNS_NAMESPACE) get pods -l job-name=postgres-init-job -o json | jq -r '.items[].status.phase'); \
        if [ "$$status" = "Succeeded" ]; then \
            echo "Database is ready.."; \
            break; \
        else \
            echo "Database is not initialized. Waiting..."; \
            sleep 10; \
        fi; \
    done

pdns-auth-install:
	printf '%s' "$$(cat ./pdns-auth/secret.yaml | sed 's|{{POSTGRES_DB_SECRET}}|$(POSTGRES_DB_SECRET)|g')" | kubectl -n $(PDNS_NAMESPACE) apply -f -
	kubectl -n $(PDNS_NAMESPACE) apply -f ./pdns-auth/configmap.yaml
	kubectl -n $(PDNS_NAMESPACE) apply -f ./pdns-auth/deployment.yaml
	kubectl -n $(PDNS_NAMESPACE) apply -f ./pdns-auth/services.yaml
	printf '%s' "$$(cat ./pdns-auth/ingressroutes.yaml | sed 's|{{DOMAIN}}|$(DOMAIN)|g')" | kubectl -n $(PDNS_NAMESPACE) apply -f -

pdns-recursor-install:
	printf '%s' "$$(cat ./pdns-recursor/configmap.yaml \
	| sed 's|{{DOMAIN}}|$(DOMAIN)|g' \
	| sed 's|{{PUBLIC_RESOLVER}}|$(PUBLIC_RESOLVER)|g' \
	| sed 's|{{PDNS_RECURSOR_QUIET}}|$(PDNS_RECURSOR_QUIET)|g' \
	| sed 's|{{PDNS_RECURSOR_LOGLEVEL}}|$(PDNS_RECURSOR_LOGLEVEL)|g')" | \
	kubectl -n $(PDNS_NAMESPACE) apply -f -
	
	kubectl -n $(PDNS_NAMESPACE) apply -f ./pdns-recursor/secret.yaml
	kubectl -n $(PDNS_NAMESPACE) apply -f ./pdns-recursor/deployment.yaml
	kubectl -n $(PDNS_NAMESPACE) apply -f ./pdns-recursor/services.yaml
	printf '%s' "$$(cat ./pdns-recursor/ingressroutes.yaml | sed 's|{{DOMAIN}}|$(DOMAIN)|g')" | kubectl -n $(PDNS_NAMESPACE) apply -f -

delete:
	kubectl -n $(PDNS_NAMESPACE) delete -f ./pdns-auth --ignore-not-found=true
	kubectl -n $(PDNS_NAMESPACE) delete -f ./pdns-recursor --ignore-not-found=true
	kubectl -n $(PDNS_NAMESPACE) delete -f ./postgres-db --ignore-not-found=true
	helm -n $(PostgreSQL_OPERATOR_NAMESPACE) uninstall postgres-operator
	kubectl delete ns $(PostgreSQL_OPERATOR_NAMESPACE)
	kubectl delete ns $(PDNS_NAMESPACE)