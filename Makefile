REPO = chatwork

.PHONY: build
build:
	docker build -t $(REPO)/`basename $$PWD` .;
	@version=$$(docker inspect -f {{.Config.Labels.version}} $(REPO)/`basename $$PWD`); \
		if [ -n "$$version" ]; then \
			docker tag $(REPO)/`basename $$PWD`:latest $(REPO)/`basename $$PWD`:$$version; \
		fi

.PHONY: check
check:
	@version=$$(docker inspect -f {{.Config.Labels.version}} $(REPO)/`basename $$PWD`); \
		if [ -z "$$version" ]; then \
			echo "\033[91mError: version is not defined in Dockerfile.\033[0m"; \
			exit 1; \
		fi;
	@echo "\033[92mno problem.\033[0m";

.PHONY: test
test:
	docker-compose -f docker-compose.test.yml run --rm sut;

.PHONY: push
push:
	@version=$$(docker inspect -f {{.Config.Labels.version}} $(REPO)/`basename $$PWD`); \
		if docker inspect --format='{{index .RepoDigests 0}}' $(REPO)/$$(basename $$PWD):$$version >/dev/null 2>&1; then \
			echo "no changes"; \
		else \
			docker push $(REPO)/`basename $$PWD`:latest; \
			docker tag $(REPO)/`basename $$PWD` $(REPO)/`basename $$PWD`:$$version; \
			docker push $(REPO)/`basename $$PWD`:$$version; \
		fi
