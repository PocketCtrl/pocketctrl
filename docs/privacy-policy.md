# Privacy policy

Read the [PocketCtrl privacy policy](https://www.pocketctrl.com/privacy) for
information about local app data, encrypted device traffic, permissions,
on-device dictation, website hosting, support communications, and deletion choices.

Privacy questions: [hello@talkupapp.com](mailto:hello@talkupapp.com).

The policy is maintained in the separate website repository. It is linked from
the website footer and from the app. Keep the policy, app disclosures, and actual
data practices aligned when changing features or adding services.

## Development feature: optional OpenAI Computer Use

When explicitly enabled, Computer Use sends typed or on-device-transcribed task instructions, screenshots
of the selected Mac display, and limited focused-control Accessibility context
to OpenAI using the user's API key. Screenshots can contain private information;
close sensitive content before starting a task. The key is stored in the host
Mac's Keychain and is not sent to the phone or the PocketCtrl website.

The task's conversation and usage estimate remain in app memory. Requests use
`store: false`; this is not a promise of zero provider retention. OpenAI's API data
policies and the user's account settings still apply. Diagnostic events omit task
text, typed text, screenshots, and keys. Model access refresh sends the key only
to OpenAI; the public pricing-catalog fetch contains no key or task content.

Hold-to-talk records only for an explicit robot-button hold (or the accessible
start/send action). Recognition requires on-device support, with no cloud speech
fallback. The resulting instruction text, not speech audio, goes to the Mac and
OpenAI when sent. There is no always-listening AI Voice mode. Existing optional
remote typing dictation remains separate. Update the separate website policy and applicable store disclosures
before distributing a build that includes Computer Use.
