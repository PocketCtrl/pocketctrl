# OpenAI Computer Use

Computer Use is an optional, supervised feature in the development version. The
Mac performs the task while an iPhone or iPad streams its display. It is not an
unattended agent, and it can make mistakes.

## Setup

1. Build and run the updated Mac and iOS targets.
2. On the host Mac, open **Settings → Computer Use**, enable the feature, and save
   an OpenAI API key. API billing is separate from a ChatGPT subscription.
3. Grant the paired phone or tablet **Computer Use** permission in that pane.
   Remote input, Screen Recording, and Accessibility must also be available.
4. Use **Refresh** to check which supported models the key can access. This uses
   `GET /v1/models`; it does not run inference. **Test Connection** sends a small
   billable Responses request to verify the chosen model/tool combination.
5. Connect the viewer, tap the robot, select a model and thinking level, and type
   a task. Keep the viewer foregrounded to supervise. Use Stop at any time.

The default is GPT-6 Luna with model-default thinking. GPT-6 Sol and GPT-6 Astra
are also supported. Astra does not offer the None thinking option. A task keeps
its selected model, thinking, and pricing for its lifetime, including pauses.
Model availability depends on the OpenAI project; a model-list entry alone does
not guarantee every request or tool is authorized.

## Controls and safeguards

- Tap the robot to type, or hold it until the microphone appears, speak, and
  release to send one instruction. Speech recognition stays on device; the
  resulting instruction text is sent to the Mac and OpenAI. Microphone and
  Speech Recognition permissions are required. There is no always-listening
  mode, Jev, or continuous voice-command queue.
- Opening the robot sheet during a task pauses it for editing. **Make changes**
  beside **Try again** does the same from an approval prompt and focuses the
  composer. Sending continues the same task with the new instructions, after
  the host has released pending input; it does not approve the old action.
  A cancelled hold, backgrounding, or a lost connection does not submit speech.
  Unsent corrections remain in the composer. Closing the sheet leaves the task
  paused; use Resume to continue without changes.
- Manual input is withheld while the task owns control. Stop cancels pending work
  before releasing it. Leaving or disconnecting the viewer pauses supervision.
- Sensitive actions may require an explicit Allow. The approval applies only to
  the displayed request; changed targets may need a fresh review.
- Routine typing checks the keyboard destination rather than unrelated screen
  animations; pointer actions check their hit area. A changed target triggers
  automatic screenshot-based replanning, discarding unexecuted actions and
  reporting partial batches to the model. Three retries per task segment bound
  this recovery. Display changes or unavailable screen validation still pause.
  Explicit approvals retain broader screen-context checks and never transfer
  automatically to a newly planned action.
- The task sheet keeps the composer pinned above the conversation and lists the
  transcript newest-first beneath it, without repeating the same status above
  the input. Warning messages have a yellow outline. Tap the estimated cost for
  how it was calculated. **New chat** (top left) clears the finished conversation, or stops
  an owned task after confirmation; the Mac starts every task with a fresh
  transcript, so this only hides the previous run on the phone. Cost estimates
  are not spending limits or billing guarantees.
  During a task, the viewer shows an estimated dollar total below the robot and
  an execution-status bubble centered between the top controls. Tap the bubble
  to expand the full message; tap again to collapse it. Long expanded messages
  scroll within the safe area. Cost updates arrive after API responses, not token
  by token; the bubble is not private model reasoning.
- Set appropriate limits in the OpenAI project and avoid sensitive applications
  while testing. Screenshots and focused-control context are sent to OpenAI.

The API key stays in the host Mac's Keychain. No key or screenshot is included in
the model catalog. See [privacy notes](privacy-policy.md).

## Model data and verification

Official model IDs are `gpt-6-luna`, `gpt-6-sol`, and `gpt-6-astra`. Capabilities
and Standard token rates were checked on 2026-09-22 against the official
[Luna](https://developers.openai.com/api/docs/models/gpt-6-luna),
[Sol](https://developers.openai.com/api/docs/models/gpt-6-sol), and
[Astra](https://developers.openai.com/api/docs/models/gpt-6-astra) documentation.
The integration uses the [Responses computer tool](https://developers.openai.com/api/docs/guides/tools-computer-use).

`distribution/ai/openai-models.json` is the reviewed public catalog. The app has
an identical bundled fallback; it rejects malformed catalogs and older revisions.
The separate website may publish the JSON at `/ai/openai-models.json`. The OpenAI
model-list API supplies availability, not pricing or supported thinking levels.
If that website endpoint is unavailable, the app keeps using its validated cached
or bundled catalog; publishing source does not deploy the website catalog.

## Before distributing a build

- Update the separate website privacy policy and applicable store disclosures for
  the optional OpenAI data flow, including on-device-transcribed instructions.
- Publish the reviewed model catalog if website-delivered pricing updates are wanted.
- Test an existing paired device: ordinary remote control must still work, while
  Computer Use remains unavailable until explicitly granted on the Mac.
- Test Allow, Try again, Make changes, Stop, disconnect/reconnect, backgrounding,
  and hold-to-talk cancellation on real devices. Confirm that a lost connection
  never automatically resumes a task or submits a queued instruction.

Run `zsh script/test_computer_use.sh` for mocked protocol, ownership, approval,
input, model-selection, API-payload, pricing, and catalog regression tests. These
tests do not spend API credits or control real desktop applications. A supervised
live task on each model remains part of release testing.
