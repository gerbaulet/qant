# TestFlight deployment

Quant can be archived, uploaded, and distributed from the repository root:

```sh
make ios-testflight
```

The command asks for the German “What to Test” changelog, shows the version,
next build number, and target groups, and requires confirmation before building
or uploading anything.

The internal group `Tester` receives processed builds through its automatic
distribution setting in App Store Connect. Fastlane explicitly assigns the
build to the external group `Externe Tester`, requests external beta review
when Apple requires it, and notifies external testers after approval.

## One-time local setup

1. Install the pinned Fastlane dependencies:

   ```sh
   make ios-testflight-setup
   ```

2. If App Store Connect API access is not enabled yet, the Account Holder must
   request it under **Users and Access > Integrations > App Store Connect API**
   and wait for Apple's approval.
3. Create an App Store Connect team API key with the **App Manager** role.
4. Download its `.p8` private key to a location outside this repository.
5. Copy `apps/ios/fastlane/.env.example` to `apps/ios/fastlane/.env` and enter
   the key ID, issuer ID, and absolute path to the `.p8` file.

`fastlane/.env`, private keys, archives, and generated packages are ignored by
Git. Treat the `.p8` file like a password: it can only be downloaded once and
must be revoked in App Store Connect if it is exposed.

Every upload uses the next TestFlight build number without modifying the Xcode
project. Build products are created in a temporary directory and removed after
the upload finishes.
