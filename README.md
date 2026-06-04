[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/we-promise/sure)
[![View performance data on Skylight](https://badges.skylight.io/typical/s6PEZSKwcklL.svg)](https://oss.skylight.io/app/applications/s6PEZSKwcklL)
[![Dosu](https://raw.githubusercontent.com/dosu-ai/assets/main/dosu-badge.svg)](https://app.dosu.dev/a72bdcfd-15f5-4edc-bd85-ea0daa6c3adc/ask)
[![Pipelock Security Scan](https://github.com/we-promise/sure/actions/workflows/pipelock.yml/badge.svg)](https://github.com/we-promise/sure/actions/workflows/pipelock.yml)

<img width="1270" height="1140" alt="sure_shot" src="https://github.com/user-attachments/assets/9c6e03cc-3490-40ab-9a68-52e042c51293" />

<p align="center">
  <!-- Keep these links. Translations will automatically update with the README. -->
  <a href="https://readme-i18n.com/de/we-promise/sure">Deutsch</a> | 
  <a href="https://readme-i18n.com/es/we-promise/sure">Español</a> | 
  <a href="https://readme-i18n.com/fr/we-promise/sure">Français</a> | 
  <a href="https://readme-i18n.com/ja/we-promise/sure">日本語</a> | 
  <a href="https://readme-i18n.com/ko/we-promise/sure">한국어</a> | 
  <a href="https://readme-i18n.com/pt/we-promise/sure">Português</a> | 
  <a href="https://readme-i18n.com/ru/we-promise/sure">Русский</a> | 
  <a href="https://readme-i18n.com/zh/we-promise/sure">中文</a>
</p>

# Sure: The personal finance app for everyone

<b>Get
involved: [Discord](https://discord.gg/36ZGBsxYEK) • [Website](https://sure.am) • [Issues](https://github.com/we-promise/sure/issues)</b>

> [!IMPORTANT]
> This repository is a fork of [we-promise/sure](https://github.com/we-promise/sure), which is itself a community fork of the now-abandoned [Maybe Finance](https://github.com/maybe-finance/maybe) project. <br />
> This fork is not affiliated with or endorsed by Maybe Finance Inc. or the upstream Sure maintainers.

## What This Fork Adds

This fork builds on Sure with additional work around AI-assisted categorization, statement import, and Singapore-aware personal finance workflows.

- AI category wizard for reviewing suggested categories and applying transaction categorization changes.
- PDF/CSV statement import pipeline with processing progress, review controls, and enrichment support.
- OpenAI/Codex-backed provider work for AI categorization and statement extraction.
- Singapore-focused import/reporting improvements, including CPF, DBS, and IBKR statement handling.

For the detailed fork comparison, including remotes and rewritten-history context, see [FORK.md](FORK.md).

## Backstory

The Maybe Finance team spent most of 2021–2022 building a full-featured personal finance and wealth management app. It even included an “Ask an Advisor” feature that connected users with a real CFP/CFA — all included with your subscription.

The business end of things didn't work out, and so they stopped developing the app in mid-2023.

After spending nearly $1 million on development (employees, contractors, data providers, infra, etc.), the team open-sourced the app. Their goal was to let users self-host it for free — and eventually launch a hosted version for a small fee.

They actually did launch that hosted version … briefly.

That also didn’t work out — at least not as a sustainable B2C business — which led to Sure, a community-maintained fork. This repository builds on that fork with additional product and localization work.

Join us!

## Hosting Sure

Sure is a fully working personal finance app that can be [self hosted with Docker](docs/hosting/docker.md).

## Forking and Attribution

This repo is a fork of `we-promise/sure`, which is a community fork of the archived Maybe Finance repo.
You’re free to fork it under the AGPLv3 license.

To stay compliant and avoid trademark issues:

- Be sure to include the original [AGPLv3 license](https://github.com/maybe-finance/maybe/blob/main/LICENSE) and clearly state in your README that your fork is based on Sure and Maybe Finance but is **not affiliated with or endorsed by** Maybe Finance Inc. or the upstream Sure maintainers.
- "Maybe" is a trademark of Maybe Finance Inc. and therefore, use of it is NOT allowed in forked repositories (or the logo)

## Performance Issues

With data-heavy apps, inevitably, there are performance issues. We've set up a public dashboard showing the problematic requests seen on the demo site, along with the stacktraces to help debug them.

[https://www.skylight.io/app/applications/s6PEZSKwcklL/recent/6h/endpoints](https://oss.skylight.io/app/applications/s6PEZSKwcklL/recent/6h/endpoints)

Any contributions that help improve performance are very much welcome.

## Local Development Setup

**If you are trying to _self-host_ the app, [read this guide to get started](docs/hosting/docker.md).**

The instructions below are for developers to get started with contributing to the app.

### Requirements

- See `.ruby-version` file for required Ruby version
- PostgreSQL >9.3 (latest stable version recommended)
- Redis > 5.4 (latest stable version recommended)

### Getting Started
```sh
cd sure
cp .env.local.example .env.local
bin/setup
bin/dev

# Optionally, load demo data
rake demo_data:default
```

Visit http://localhost:3000 to view the app.

If you loaded the optional demo data, log in with these credentials:

- Email: `user@example.com`
- Password: `Password1!`

For further instructions, see guides below.

### Setup Guides

- [Mac dev setup](https://github.com/we-promise/sure/wiki/Mac-Dev-Setup-Guide)
- [Linux dev setup](https://github.com/we-promise/sure/wiki/Linux-Dev-Setup-Guide)
- [Windows dev setup](https://github.com/we-promise/sure/wiki/Windows-Dev-Setup-Guide)
- Dev containers - visit [this guide](https://code.visualstudio.com/docs/devcontainers/containers)

### One-click Install

[![Run on PikaPods](https://www.pikapods.com/static/run-button.svg)](https://www.pikapods.com/pods?run=sure)

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/T_draF?referralCode=CW_fPQ)

### Managed OpenClaw for Sure Finances

<a href="https://kilocode.pxf.io/repo-readme"><img src="https://kilo.ai/kiloclaw/partner-resources/kiloclaw-logo-yellow-bg-typography.png" alt="Managed OpenClaw for Sure Finances" width="185"/></a>


## License and Trademarks

Maybe, Sure, and this fork are distributed under
an [AGPLv3 license](https://github.com/we-promise/sure/blob/main/LICENSE).
- "Maybe" is a trademark of Maybe Finance, Inc.
- "Sure" refers to the upstream community fork at `we-promise/sure`.

![Alt](https://repobeats.axiom.co/api/embed/3a9753cff07501fba8a6749d0ebd567ff63848c8.svg "Repobeats analytics image")
