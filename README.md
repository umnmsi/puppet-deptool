# puppet-deptool

`puppet-deptool` is a utility for parsing Puppet module code to determine dependencies.

## Motivation

Puppet modules almost always rely on other modules and it can be tedious to determine the list of modules to include in the module metadata or the fixtures file used in spec testing. This utility attempts to scan module code to determine the dependencies and update the module metadata and fixtures file as needed. This utility can also be used to help ensure all code within a Puppet environment has its dependencies met and avoids duplicate definitions.

## Overview

`puppet-deptool` can work with a standalone module, but in general it assumes there is a control repository with a `Puppetfile` containing the specific modules available in the environment. If provided a control repository, the utility can use r10k to deploy the environment to a temporary location, scan each module within the environment to determine each class, type and function provided, and attempt to resolve which modules are required by the code within the module or modules being evaluated. Any classes, types, or functions that remain unresolved will be also be listed. If requested, the utility can update the module metadata.json dependencies and the spec fixtures.yml file to include the resolved dependencies.

## Key Features

- Updates the dependencies in the module `metadata.json` if requested
- Generates the module RSpec `fixtures.yml` file based on a control repository `Puppetfile` if requested
- Generates a state file for a control repository to eliminate the need to deploy and scan the environment modules on each run if requested
- Generates a known warnings file to prevent known issues from triggering warning messages and non-zero exit codes if requested

## Known limitations

Some of the functionality is highly customized for use within the organization that developed the utility. Contributions to make this functionality more broadly applicable are greatly welcomed.

## Usage

The core of the utility is the `check_dependencies` command. A detailed list of options is available with the `--help` parameter.

### Core options

- `-b`, `--basedir DIR` - Set the base directory for the module or control repository
- `-c`, `--controldir DIR` - Use a specific control repository directory
- `-d`, `--deploy-environment` - Run `r10k` deploy for the environment
- `-e`, `--environment ENVIRONMENT` - Target environment and enable deploy/force
- `-f`, `--state-file FILE` - Use a generated state file instead of scanning
- `-g`, `--generate-state-file` - Write the current parsed state to disk
- `-k`, `--known-warnings FILE` - Load known warnings to ignore
- `-l`, `--list-deps` - Output resolved module dependencies
- `-m`, `--module MODULE` - Restrict dependency resolution to one or more modules
- `-p`, `--modulepath DIR` - Add modulepath entries for scanning
- `-r`, `--recurse` - Recursively include transitive dependencies
- `-s`, `--scan MODULE` - Limit the parse scan to named modules
- `-u`, `--use-generated-state` - Avoid scanning and use generated state instead
- `-V`, `--validate-state` - Check state against the control repository Puppetfile
- `-M`, `--update-metadata` - Update module metadata with dependency constraints
- `-X`, `--update-fixtures` - Generate `.fixtures.yml` for fixture-based testing
- `-w`, `--warnings-ok` - Do not fail on warnings

### Examples

#### Determine this list of direct dependencies for a module given a deployed Puppet environment

```bundle exec check_dependencies --basedir </path/to/module> --controldir </path/to/deployed/environment> --module <name of module> --list-deps```

#### Determine this list of recursive dependencies for a module given a deployed Puppet environment (as needed in spec testing for example)

```bundle exec check_dependencies --basedir </path/to/module> --controldir </path/to/deployed/environment> --module <name of module> --list-deps --recurse```

## Types of warnings

- Duplicate definitions - Any definitions that appear in more than one manifest
- Missing definitions - Any references that were not resolved during scanning
- Type errors - Any types that had warnings or errors during loading
- Control module dependencies - Any modules that reference modules only present in the control repository (hardcoded to `profile` and `role`)
- Missing metadata - Any modules that have a missing or invalid `metadata.json` file