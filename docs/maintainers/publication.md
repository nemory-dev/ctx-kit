# Public repository publication checklist

Use this checklist before sharing a change or changing repository metadata. It covers publication hygiene and discoverability, not a guarantee that all sensitive data or security issues have been found.

## Review the files and author identity

1. Review tracked changes and new files. Keep private context, credentials, real conversation logs, and machine-specific paths out of patches and attachments.
2. Stage explicit paths and inspect `git diff --cached` and `git diff --cached --check`. Ignore rules do not remove files that are already tracked.
3. Inspect the identity that Git will use for new commits. For privacy, use the public account name and the exact no-reply address shown in GitHub email settings. Prefer repository-local configuration when other projects need a different identity.
4. Review both author and committer metadata. Changing configuration affects future commits only; it does not remove old identities.
5. If sensitive content already exists in history, follow the [history-removal guidance](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository). Revoke exposed credentials first. Coordinate any rewrite separately, including affected branches, PR references, and existing clones.

See [GitHub commit email settings](https://docs.github.com/en/account-and-profile/how-tos/email-preferences/setting-your-commit-email-address) for the supported configuration flow. Do not paste an email address or private audit output into a public issue when asking for help.

## Make the project understandable and contributable

- Keep an accurate About description and topics describing implemented capabilities. Do not advertise a package, hosted service, semantic search, or integration that is not shipped.
- Maintain a license file consistent with the README, a contribution guide, issue and PR templates, a code of conduct, and a truthful security-reporting route.
- Check that a newcomer can find prerequisites, a safe first run, test commands, and small contribution opportunities.
- Preserve the distinction between CLI tests, browser simulation, user-reported manual checks, and untested environments.
- Verify both required PR checks before merging and the separate `main` push checks afterward.

GitHub's [community profile](https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/about-community-profiles-for-public-repositories) and [topics guide](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/classifying-your-repository-with-topics) describe how these files and metadata are discovered. Files in a work branch do not update the default branch's community profile until merged.

## Check search discoverability without promising rankings

- Check that the public repository URL responds successfully and that observed robots metadata does not prohibit indexing. GitHub manages the page HTML and robots policy; adding a `robots.txt` or meta tag to repository source does not change the GitHub repository page's policy.
- Compare broad searches with an exact project-and-owner query. A short project name can match unrelated projects. Record the actual query and observation rather than claiming a ranking change from memory.
- Search tools may use different indexes. Do not label a generic search-tool result as a verified Google result.
- Google documents that `site:` results are not exhaustive and indexing is not guaranteed. Missing results alone do not prove deindexing. [Google site operator](https://developers.google.com/search/docs/monitor-debug/search-operators/all-search-site), [technical requirements](https://developers.google.com/search/docs/essentials/technical).
- Improve the README and public metadata for people first. A descriptive project page and relevant topics help discovery, but do not promise immediate Google exposure. For a separately owned documentation site, use the ownership-verified Search Console workflow; do not assume repository write access provides control of GitHub's domain.

Do not upload private user contexts, contact information, or internal audit findings to a demo or documentation site to improve search visibility.
