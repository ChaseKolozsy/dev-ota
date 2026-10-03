# Terminal record-button errors

Terminal voice input keeps the existing saved OpenAI key. A key being present
in secure storage does not establish that a transcription request succeeded.
The key dialog is only prompted when the loaded key is absent or blank.

The record button now displays failures both in the terminal status and in an
eight-second snackbar. Missing keys, denied microphone permission, failed
recorder start/stop, missing or empty audio, empty transcription text, malformed
responses, rejected authentication, denied access, request/billing limits,
network failures and timeouts no longer silently disappear. A failed recorder
stop leaves the Stop button available for retry. Transcription failures restore
the controls, retain the existing composer text and keep recording-file cleanup.
Duplicate taps while starting or stopping are suppressed.

HTTP error categories follow the
[official OpenAI error guidance](https://developers.openai.com/api/docs/guides/error-codes).
Only known status and quota codes determine the displayed message; raw response
bodies, API keys and raw exception details are never placed in the error message.
Audio is still sent to OpenAI for this explicitly requested transcription feature.
The phone-local terminal outcome checker is a separate flow.

Regression checks use a fake HTTP adapter and a fake recorder, including a saved
key followed by an HTTP 401 response. No real API request, phone credential or
paid transcription was used. These checks prove visible failure handling; they
do not establish the cause of the user's original phone failure. The next phone
attempt should reveal its error category.
