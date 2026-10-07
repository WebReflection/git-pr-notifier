# git-pr-notifier

Currently tested on macOS - **experimental**

  * `mv config.env.example config.env` before or after changing variables
  * verify settings for `kilo-ai.json` to be sure are the desirable one
  * `./start.sh` to start the crontab work (requires authorization) - `./start.sh` to restart it
  * `./stop.sh` to stop the crontab work if active (requires authorization)
  * `./start.sh clean` to erase `cron_check.log` and transient state: `state/parsed_prs.json` and `state/retries.json` are kept since they make the bootstrap faster, while the whole `state` folder gets removed when neither exists (refused if a check is in flight)

This should check and validate via Kilocode AI your chosen peer within its PRs and, once everything is fine, it should notify you about it, or inform you there were issues.

That's it, feel free to contribute 👋
