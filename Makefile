.PHONY: release

release:
	@echo "Running release"
	@.scripts/releaseServiceToClients.sh
