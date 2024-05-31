#########################
### Variables Section ###
#########################

.ONESHELL:
# PostgreSQL OPERATOR Variables
PostgreSQL_OPERATOR_NAMESPACE := postgres
PostgreSQL_OPERATOR_VERSION := 1.10.1

# PowerDNS Variables 
POSTGRES_DB_SECRET = $(shell kubectl get secret pdns.pdns-postgres-db.credentials.postgresql.acid.zalan.do -n $(PDNS_NAMESPACE) -o json | jq '.data | map_values(@base64d)' | jq -r '.password')
DOMAIN = example.com
PDNS_NAMESPACE := pdns


###########################
### Deployment Section ####
###########################
all: prep postgres-db-install wait_for_postgresql postgres-db-init pdns-auth-install pdns-recursor-install

prep:
# PostgreSQL Operator
	kubectl create namespace $(PostgreSQL_OPERATOR_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	helm repo add postgres-operator-charts https://opensource.zalando.com/postgres-operator/charts/postgres-operator
	
# PowerDNS Namespace
	kubectl create PDNS_NAMESPACE $(PDNS_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -

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

pdns-auth-install:
	printf '%s' "$$(cat ./pdns-auth/configmap.yaml | sed 's|{{POSTGRES_DB_SECRET}}|$(POSTGRES_DB_SECRET)|g')" | kubectl -n $(PDNS_NAMESPACE) apply -f -
	kubectl -n $(PDNS_NAMESPACE) apply -f ./pdns-auth/deployment.yaml
	kubectl -n $(PDNS_NAMESPACE) apply -f ./pdns-auth/services.yaml
	printf '%s' "$$(cat ./pdns-auth/ingressroutes.yaml | sed 's|{{DOMAIN}}|$(DOMAIN)|g')" | kubectl -n $(PDNS_NAMESPACE) apply -f -

pdns-recursor-install:
	printf '%s' "$$(cat ./pdns-recursor/configmap.yaml | sed 's|{{DOMAIN}}|$(DOMAIN)|g')" | kubectl -n $(PDNS_NAMESPACE) apply -f -
	kubectl -n $(PDNS_NAMESPACE) apply -f ./pdns-recursor/deployment.yaml
	kubectl -n $(PDNS_NAMESPACE) apply -f ./pdns-recursor/services.yaml
	printf '%s' "$$(cat ./pdns-recursor/ingressroutes.yaml | sed 's|{{DOMAIN}}|$(DOMAIN)|g')" | kubectl -n $(PDNS_NAMESPACE) apply -f -

delete:
	kubectl -n $(PDNS_NAMESPACE) delete -f ./pdns-auth --ignore-not-found=true
	kubectl -n $(PDNS_NAMESPACE) delete -f ./pdns-recursor --ignore-not-found=true
	kubectl -n $(PDNS_NAMESPACE) delete -f ./postgres-db --ignore-not-found=true
	kubectl delete ns $(PDNS_NAMESPACE)