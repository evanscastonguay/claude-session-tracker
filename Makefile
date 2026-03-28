APP_NAME = ClaudeTracker
BUILD_DIR = .build/release
BUNDLE = $(APP_NAME).app
PLIST = scripts/com.evanscastonguay.claude-tracker.plist
LAUNCH_AGENT_DIR = $(HOME)/Library/LaunchAgents
LAUNCH_AGENT = $(LAUNCH_AGENT_DIR)/com.evanscastonguay.claude-tracker.plist

.PHONY: build bundle run clean install uninstall install-hooks uninstall-hooks install-launchagent uninstall-launchagent install-all uninstall-all restart

build:
	swift build -c release

bundle: build
	@rm -rf $(BUNDLE)
	@mkdir -p $(BUNDLE)/Contents/MacOS
	@mkdir -p $(BUNDLE)/Contents/Resources
	@cp $(BUILD_DIR)/$(APP_NAME) $(BUNDLE)/Contents/MacOS/
	@cp Info.plist $(BUNDLE)/Contents/
	@echo "Built $(BUNDLE)"

run: bundle
	@pkill -f $(BUNDLE) 2>/dev/null || true
	@sleep 1
	@open $(BUNDLE)

clean:
	swift package clean
	rm -rf $(BUNDLE)

# Install app to ~/Applications
install: bundle
	@mkdir -p ~/Applications
	@pkill -f $(APP_NAME).app 2>/dev/null || true
	@sleep 1
	@rm -rf ~/Applications/$(BUNDLE)
	@cp -R $(BUNDLE) ~/Applications/
	@echo "Installed to ~/Applications/$(BUNDLE)"

uninstall:
	@pkill -f $(APP_NAME).app 2>/dev/null || true
	@rm -rf ~/Applications/$(BUNDLE)
	@echo "Uninstalled ~/Applications/$(BUNDLE)"

# Hooks
install-hooks:
	@bash scripts/install-hooks.sh

uninstall-hooks:
	@bash scripts/uninstall-hooks.sh

# LaunchAgent (auto-start on login)
install-launchagent: install
	@mkdir -p $(LAUNCH_AGENT_DIR)
	@cp $(PLIST) $(LAUNCH_AGENT)
	@launchctl bootout gui/$$(id -u)/com.evanscastonguay.claude-tracker 2>/dev/null || true
	@launchctl bootstrap gui/$$(id -u) $(LAUNCH_AGENT)
	@echo "LaunchAgent installed — app will start on login"

uninstall-launchagent:
	@launchctl bootout gui/$$(id -u)/com.evanscastonguay.claude-tracker 2>/dev/null || true
	@rm -f $(LAUNCH_AGENT)
	@echo "LaunchAgent removed"

# Full install/uninstall
install-all: install install-hooks install-launchagent
	@open ~/Applications/$(BUNDLE)
	@echo "Full install complete!"

uninstall-all: uninstall-hooks uninstall-launchagent uninstall
	@rm -rf ~/.claude-tracker
	@echo "Full uninstall complete!"

# Dev: rebuild and restart
restart: bundle
	@pkill -f $(APP_NAME).app 2>/dev/null || true
	@sleep 1
	@open $(BUNDLE)
