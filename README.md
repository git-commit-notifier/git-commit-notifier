# Git Commit Notifier

[![build status](https://secure.travis-ci.org/git-commit-notifier/git-commit-notifier.png)](https://travis-ci.org/git-commit-notifier/git-commit-notifier)
[![Code Climate](https://codeclimate.com/github/git-commit-notifier/git-commit-notifier.png)](https://codeclimate.com/github/git-commit-notifier/git-commit-notifier)
[![Coverage Status](https://coveralls.io/repos/git-commit-notifier/git-commit-notifier/badge.png?branch=master)](https://coveralls.io/r/git-commit-notifier/git-commit-notifier)

## Description

This gem sends email commit messages splitting commits that were pushed in one step.
The Email is delivered as text or HTML with changes refined per word. Emails
have a scannable subject containing the first sentence of the commit as well
as the author, project and branch name.

It's also possible to send a mail to a newsgroup using NNTP.

For example:

    [rails][branch] Fix Brasilia timezone. [#1180 state:resolved]

A reply-to header is added containing the author of the commit. This makes
follow up really simple. If multiple commits are pushed at once, emails are
numbered in chronological order:

    [rails][branch][0] Added deprecated warning messages to Float#months and Float#years deprications.
    [rails][branch][1] Enhance testing for fractional days and weeks. Update changelog.

Example email:

![Example](http://img171.imageshack.us/img171/954/gitcommitnotifieremailpq3.png "Example")

__by Bodo Tasche (bodo 'at' wannawork 'dot' de), Akzhan Abdulin (akzhan 'dot' abdulin 'at' gmail 'dot' com), Csoma Zoltan  (info 'at' railsprogrammer 'dot' net)__

## Requirements

* Ruby 1.8.7 or higher.
* RubyGems.
* libxml2 and libxslt with headers (see [nokogiri installation notes](http://nokogiri.org/tutorials/installing_nokogiri.html) for details).

We do not support ruby 1.8.6 because of nokogiri gem requirements.

## Installing and Configuring

Install the gem:

```bash
gem install git-commit-notifier
```

After you installed the gem, you need to configure your git repository. Add a file called
"post-receive" to the "hooks" directory of your git repository with this content:

```bash
#!/bin/sh
git-commit-notifier path_to_config.yml
```

(Don't forget to make that file executable.)

An example for the config file can be found in [config/git-notifier-config.example.yml](http://github.com/git-commit-notifier/git-commit-notifier/blob/master/config/git-notifier-config.example.yml).

If you want to send mails on each commit instead on each push, you should add a file called "post-commit" with this content:

```bash
#!/bin/sh
echo "HEAD^1 HEAD refs/heads/master" | git-commit-notifier path_to_config.yml
```

## Decorate files and commit ids with link to a webview
You need change next line in config file ```link_files: none```

Possible values: none, gitweb, gitorious, cgit, trac, gitlabhq, or redmine

* "cgit" you can omit "project". In this case repository name will be used by default

## Integration with Redmine, Bugzilla, MediaWiki

Git-commit-notifier supports easy integration with Redmine, Bugzilla and MediaWiki. All you need is to uncomment the according line in the configuration and change the links to your software installations instead of example ones (no trailing slash please).

* "BUG 123" sentence in commit message will be replaced with link to bug in Bugzilla.
* "refs #123" and "fixes #123" sentences in commit message will be replaced with link to issue in Redmine.
* "[[SomePage]]" sentence in commit message will be replaced with link to page in MediaWiki.

## Github-flavored Webhooks

Git-commit-notifier can send a webhook just after sending a mail, This webook will be sent in a POST request to a server specified in the configuration (webhook / url), under JSON format following the same syntax as Github webhooks.

* [Cogbot](https://github.com/mose/cogbot) is the irc bot for which that feature was originaly designed for. Only a subset of the Github json file was required for that one so maybe it won't work on all Github webhook recievers.
* [Github webhooks](https://help.github.com/articles/post-receive-hooks) describes the json format expected and some hints on how to design a webhook reciever.  Be sure to extract the 'ref' from the json.  An example Sinatra server to use git-commit-notifier might look like:

```ruby
require 'rubygems'
require 'json'
require 'sinatra'

post '/' do
  if params[:payload]
    push = JSON.parse(params[:payload])

    repo = push['repository']['name']
    before_id = push['before']
    after_id = push['after']
    ref = push['ref']

    system("/usr/local/bin/change-notify.sh #{repo} #{before_id} #{after_id} #{ref}")
  end
end
```

change-notify.sh might look like:

```sh
#!/bin/sh

set -e

EXPECTED_ARGS=4
E_BADARGS=65

if [ $# -ne $EXPECTED_ARGS ]
then
    echo "Usage: `basename $0` {repo} {before commit ID} {after commit ID} {ref}"
    exit $E_BADARGS
fi

REPO=$1
BEFORE=$2
AFTER=$3
REF=$4
CONFIG=myconfig.yml

# Assume repository exists in directory and user has pull access
cd /repository/$REPO
git pull
echo $BEFORE $AFTER $REF | /usr/local/bin/git-commit-notifier $CONFIG
```

## Integration of links to other websites

If you need integration with other websites not supported by git-commit-notifier you can use the message\_map property. For that you need to know the basics of regular expressions syntax.

Each key of message\_map is a case sensitive Regexp pattern, and its value is the replacement string.
Every matched group (that defined by round brackets in regular expression) will be automatically substituted instead of \1-\9 backreferences in replacement string where the number after the backslash informs which group should be substituted instead of the backreference. The first matched group is known as \1.

For example, when we need to expand "follow 23" to http://example.com/answer/23, simply type this:

```yaml
  '\bfollow\s+(\d+)': 'http://example.com/answer/\1'
```

Key and value are each enclosed in single quotes. \b means that "follow" must not be preceded by other word chars, so "befollow" will not match but "be follow" will match. After "follow" we expect one or more spaces followed by group of one or more digits. The \1 in the result url will be replaced with the matched group.

More examples can be found in the config file.

## Logic of commits handling

By default all commits are tracked through the whole repository so after a merge
you should not receive messages about those commits already posted in other branches.

This behaviour can be changed using unique\_commits\_per\_branch option. When it's true,
you should receive new message about commit when it's merged in other branch.

Yet another option, skip\_commits\_older\_than (in days), should be used to not inform about
old commits in processes of forking, branching etc.

## Note on development

It's easy to fork and clone our repository.

Next step is installation of required dependencies:

```bash
cd $GCN_REPO
bundle install
rake # Run specs
```

or

```bash
gem build git-commit-notifier.gemspec
[sudo] gem install git-commit-notifier-0.11.10.gem
```

Now you can create test configuration file (example provided in `config` directory) and test your code over any test repository in this manner:

```bash
cd $TEST_REPO
echo "HEAD^1 HEAD refs/heads/master" | $GCN_REPO/local-run.rb $PATH_TO_YAML_CONFIG
```

## Note on Patches/Pull Requests

* Fork [the project](https://github.com/git-commit-notifier/git-commit-notifier).
* Make your feature addition or bug fix.
* Add tests for it. This is important so I don't break it in a
  future version unintentionally.
* Commit, do not mess with rakefile, version, or history.
  (if you want to have your own version, that is fine but bump version in a commit by itself I can ignore when I pull)
* Send me a pull request. Bonus points for topic branches.

## Credits

Thanks for [putpat.tv](http://www.putpat.tv), [Primalgrasp](http://www.primalgrasp.com) and [Undev](http://undev.ru/) for sponsoring this work.

## License

MIT License, see the {file:LICENSE}.

