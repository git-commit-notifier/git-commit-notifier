# Changes

## Version 0.11.9.1

* Display info message if the config.yml specified is not found.
* Strip whitespace after splitting emails for SMTP.
* Added prefer_git_config_mailinglist config variable.

## Version 0.11.9

* Notifier now do not falls on invalid utf-8 text in diffs.
* Fixes erroneous 0.11.7 release (partially incomplete code was pushed to rubygems and breaks ruby 1.8 compatibility).

## Version 0.11.7

* Summary email section has been updated to be shown correctly.
* More fine-grained values for ignore_whitespace option (all, change, none).
* Add support for gitlabhq 4.0+ namespace repo arrangement.
* Correct urls to cgit installations.
* Correct Trac integration.
* Support for GitHub WebHooks (as client).
* Fix mailformed tag notifications.
* A lot of other fixes.

## Version 0.11.6

* Project home has been moved to git-commit-notifier GitHub organization.

## Version 0.11.5

* Support for GitHub-flavoured WebHooks (as server).
* Ability to reply_to_author.
* Shows summary.
* Do not send additional email on branch creation.

## Versions 0.11.0 - 0.11.4

* Fix segmentation faults with Unicode subjects on Ruby 1.9
* A lot of refactorings.
