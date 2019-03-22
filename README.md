# snet2ig

Convert a Simplifier.NET Guide Export ZIP into an STU3 FHIR IG that is compatible with the FHIR IG Publishing Tool.

Intended for VRDR Project, but may be useful for other IGs as well.

Currently only supports STU3 and XML based resources.

Written in Ruby.

## Installation

Requires Ruby (windows: https://rubyinstaller.org/) and Bundler (`gem install bundler` with a valid Ruby installation). 

Get the source by cloning the repository:

```
git clone https://github.com/nightingaleproject/snet2ig.git
```

Or by downloading: https://github.com/nightingaleproject/snet2ig/archive/master.zip

Inside the root directory, run:

```
bundle install
```

## Running:

```
bundle exec rackup
```
snet2ig should now be listening at localhost:9292
