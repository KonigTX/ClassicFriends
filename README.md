# ClassicFriends

Shows the Friends tab of World of Warcraft: Forever's Social window as a
classic friends list: one compact row per friend, online friends on top,
offline friends below a divider. The side tabs, the Battle.net status bar,
Friend Requests, Recent Allies, Quick Join and the ignore list are left as
Blizzard made them.

## Install

Drop the `ClassicFriends` folder into `Interface/AddOns` in your WoW:
Forever install and restart the client, or `/reload`.

## What a row shows

- **Status icon.** Online, away, busy or offline.
- **Name line.** `Account (Character), Level 15 Rogue`. The character part
  is gold when you can group with them and grey when you can't (another
  game, realm or faction). A star next to the game icon marks favorites.
- **Second line.** Zone or game activity, or when they were last online.
- **Game icon and invite button** on the right. The invite button is
  greyed out with the reason in its tooltip when an invite isn't possible.

Online friends come first, favorites leading each group, then Blizzard's
own friend order.

## Using it

- Left-click a friend to select them, then **Send Message** to whisper.
- Right-click a friend for Blizzard's friend menu (whisper, invite, set
  note, remove).
- Hover a friend for Blizzard's friend tooltip (characters, note,
  broadcast).
- **Add Friend** opens Blizzard's add-friend window.

## Commands

| | |
| --- | --- |
| `/classicfriends` | switch between this list and Blizzard's; the choice is saved |

## How it works

The list is a separate frame drawn over Blizzard's friends list content
frame (`SocialUIFrame.FriendsList`) and shown and hidden with it. No
Blizzard frame is hidden, moved or hooked, so the Social window's own code
runs untouched.

The tooltip, right-click menu and invite flow call Blizzard's own methods
from `FriendsListSocialCardMixin` and
`FriendsListSocialCardPartyButtonMixin`, so they behave exactly like the
stock list. Row layout, textures and colours follow the Classic Era
friends frame.

If a client update removes any of the Blizzard pieces it relies on, the
addon prints one line and leaves Blizzard's list in place.

## Compatibility

Written against Forever 1.60.1 (build 70790, `## Interface: 16001`) on an
English client. Not tested alongside other addons that change the Social
window.

## Known limits

- Battle.net friends only, the same set Blizzard's Forever list shows.
- No search box or filter menu. `/classicfriends` switches back to
  Blizzard's list when you need them.
- A long name line is cut with "…"; the tooltip has the full details.

## Development notes

Single-file addon (`ClassicFriends.lua`). `SavedVariables`:
`ClassicFriendsDB` (on/off state).

Issues: github.com/KonigTX/ClassicFriends/issues

## Licence

MIT.
