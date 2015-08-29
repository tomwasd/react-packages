#! /bin/bash

# We want errors to kill the script
set -e

# Go to root of repository
cd "$(dirname "$0")"

# Check if we are on devel, because if we are on master we should have already
# published, and if we are not on devel we are about to accidentally publish
# some branch.
git status | grep "On branch devel" &> /dev/null

if [ $? -ne 0 ]; then
  echo "Need to be on 'devel' branch to publish packages."
  exit 1
fi

# Check if there are any uncommitted changes, because we are going to be
# changing stuff and merging branches for you.
NUM_UNCOMMITTED_FILES=$({ git diff --name-only ; git diff --name-only --staged ; } | sort | uniq | wc -l | tr -d ' ')

if [ $NUM_UNCOMMITTED_FILES -ne 0 ]; then
  echo "You have uncommitted changes in your repository. Please commit or stash before publishing."
  exit 1
fi

# See which files have changed from master; these are the packages that have
# changes to the source code.
CHANGED_PACKAGE_FILES=$(git diff --name-only master | grep "^packages/")

# Call out to ruby to convert the list of changed files into a list of changed
# directories, which each correspond to one package
CHANGED_PACKAGES=$(/usr/bin/env ruby <<-EOF
  puts "$CHANGED_PACKAGE_FILES".split.map { |filename|
    filename.split("/")[1]
  }.uniq.compact
EOF)

# Find out which packages depend on the changed packages; we need to republish
# them too, in order for people to get the newest versions of everything when
# adding the package

PACKAGE_JS_FILES_THAT_REF_CHANGED=$(for CHANGED_PACKAGE in "$CHANGED_PACKAGES"; do
  git grep "$CHANGED_PACKAGE@" packages | grep .versions
done)

PACKAGES_THAT_DEPEND_ON_CHANGED=$(/usr/bin/env ruby <<-EOF
  puts "$PACKAGE_JS_FILES_THAT_REF_CHANGED".split.map { |filename|
    filename.split("/")[1]
  }.uniq.compact
EOF)

# Apparently, the only way to add a newline is to use printf instead of echo
PACKAGES_TO_REPUBLISH=$(printf "$PACKAGES_THAT_DEPEND_ON_CHANGED\n$CHANGED_PACKAGES" | sort | uniq)

echo "Packages that need to be republished:"
echo "$PACKAGES_TO_REPUBLISH"
echo

# Now, we want to ask people what versions they want to bump to
for PKG in $PACKAGES_TO_REPUBLISH; do
  PKG_VERSION=$(grep "version:" "packages/$PKG/package.js" | sed "s/^ *version: ['\"]\(.*\)['\"].*/\1/")

  echo "Package '$PKG' was at version '$PKG_VERSION'. What should the new version be?"
  read NEW_PKG_VERSION
  echo "You selected '$NEW_PKG_VERSION'."
  echo

  echo "s/\(['\"]$PKG@=?\).*?\(.*\)/\1$NEW_PKG_VERSION\2/"

  # Replace version declaration at the top of package.js
  sed -e "s/^\( *version: ['\"]\).*\(['\"].*\)/\1$NEW_PKG_VERSION\2/" -i "" "packages/$PKG/package.js"

  # Replace references to this package in other packages
  find packages/ -name "package.js" -exec sed -e "s/['\"]$PKG@=.*['\"]/$NEW_PKG_VERSION/" -i "" {} \;
done
