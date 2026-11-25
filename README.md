# Pare Studio

One Mac app for video, guides, slides and transcripts. The home screen asks what you want to do:

| Tool | What it does |
|---|---|
| **Download a Video** | Save videos from YouTube, Vimeo, webinars, Zoom and more. Crop & trim, compress, and make GIFs (from Pare Reels). |
| **Make a How-To Guide** | Record yourself doing a task in any app. Get a step-by-step guide (PDF, Word, web page, GIF), a narrated tutorial video, or a Camtasia project (from Pare Guide). |
| **Turn a Video into Slides** | Finds every slide in a recorded talk or webinar. Saves a PowerPoint (what was said becomes the speaker notes), a PDF, the slide images, a transcript, or a Camtasia project with the slides timed to the sound. |
| **Put Slides to a Recording** | You have the recording and the slide deck. Pare Studio listens and puts each slide on screen at the right moment, for a batch of recordings, then exports Camtasia projects or MP4s (from Pare Slides). |
| **Transcribe a Recording** | Turns speech into text, a Word document or captions (SRT, VTT), on this Mac. |

Everything runs on the Mac; recordings and slides are never uploaded. Claude (optional, with your Claude subscription through Claude Code, Google sign-in) writes guide steps and matches slides. Click **Connect Claude** at the top.

**Keywords:** in Put Slides to a Recording, add keywords such as `six + weeks`. They're shared by every tool: each find becomes a Camtasia marker and is listed in `Keyword finds.csv`.

## Turn a Video into Slides

1. Drop in the video.
2. If the video also shows the presenter or a webinar frame, drag a box around just the slide.
3. Choose how many slides: **Fewer slides**, **Normal** or **Every change** (every animation step).
4. Click **Find the Slides**. Remove any that aren't slides, then save.

Slides that come back later in the talk keep their first picture. The Camtasia project puts the slides on track 1 at the times they appear, and the sound on track 2.

## Install

Download `Pare-Studio-mac.zip` from the latest release, unzip it, and drag **Pare Studio** into Applications. The first time, right-click it and choose **Open**. It updates itself.

Your guides, voices and download tools from Pare Guide and Pare Reels are used as they are.

## Publish a new version

Every push to `main` builds and publishes a release. Other branches only compile (to check a change).
