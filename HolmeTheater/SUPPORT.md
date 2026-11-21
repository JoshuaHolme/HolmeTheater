# Holme Theater Support

Holme Theater is a native Jellyfin client for iPhone, iPad, and Apple TV. If something isn't working, or you have an idea for the app, I'd love to hear from you.

## Contact

- **Email:** [support@holme.tech](mailto:support@holme.tech)
- **Bug reports and feature requests:** [GitHub Issues](https://github.com/JoshuaHolme/HolmeTheater/issues)

When reporting a problem, it helps to include your device, its iOS, iPadOS, or tvOS version, your Jellyfin server version, and the steps that lead to the problem.

## Requirements

Holme Theater requires a Jellyfin media server. Jellyfin is free, open-source software you run on your own computer or server. Learn more at [jellyfin.org](https://jellyfin.org).

## Common questions

### I can't connect to my server

- Enter your server's address with or without `https://`. Without it, Holme Theater tries a secure connection first, then a regular one. For a server on your home network, that usually looks like `192.168.1.20:8096`; 8096 is Jellyfin's default port.
- On iPhone and iPad, Holme Theater needs permission to find devices on your local network. If you turned it off, go to Settings > Privacy & Security > Local Network and turn on Holme Theater.
- To connect away from home, your server has to be reachable from the internet, for example through a reverse proxy or a VPN. If you can open your server in a web browser on the same device, Holme Theater can connect to it too.

### Why does it say my connection isn't encrypted?

Your server is using plain HTTP instead of HTTPS, so your password and what you watch could be seen by others on the same network. That's usually fine on a home network you trust. To connect securely, set up HTTPS for your server; the Jellyfin documentation explains how.

### How do I sign in with Quick Connect?

1. On the device you want to sign in, choose **Use Quick Connect**. It shows a code.
2. On a device that's already signed in, whether Holme Theater or another Jellyfin app, open **Quick Connect** and enter the code.

If you don't see the option, Quick Connect may be turned off on your server. A server administrator can turn it on in the Jellyfin dashboard.

### Can I watch without an internet connection?

Yes, on iPhone and iPad. Download a movie, an episode, or a whole season, and it plays without a connection. What you watch offline is added to your Jellyfin account the next time you're online. You can browse your downloads offline, but not the rest of your library.

Signing out deletes all of your downloads from that device.

### Why are downloads on Apple TV experimental?

They work, but Apple TV handles storage differently than iPhone and iPad, and they haven't been tested enough to promise they'll always be there:

- Apple TV can delete downloads on its own, without warning, when it's running low on storage.
- Downloads can stop if the Apple TV goes to sleep or you leave the app, so keep Holme Theater open on the Downloads screen until they finish.
- Before a trip, check that everything you want is still listed in Downloads, and download anything that was removed again while you still have internet.

### A video stutters or keeps buffering

Open the player's settings and choose a lower **Quality**. Your server will convert the video to a smaller size, which helps on slower connections. Some videos have to be converted by your server before they can play at all, which depends on how powerful the server is.

### Subtitles aren't showing up

Holme Theater draws most text subtitles itself, as well as PGS, the picture-based subtitles common on Blu-ray rips. Other picture-based formats, such as DVD subtitles, have to be burned into the video by your server, which can take a moment to start and works best on a powerful server.

### How do I turn off the seasonal themes?

Open the **Themes** settings. You can turn themes off, pick one to keep all year, or choose which seasons and holidays to include.

## Privacy

Holme Theater doesn't collect any data. See the [Privacy Policy](PRIVACY.md) for details.
