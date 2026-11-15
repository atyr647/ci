#!/usr/bin/env python3
# sni-items.py - two apps' tray icons, stood in for on the session bus with GLib's own D-Bus (Gio), not ribbon::dbus,
# so the shell's watcher and host are checked against the marshalling real apps use (tests/shell-tray.tcl).
#   steam    as libappindicator registers (Steam): an object path on its own connection
#            (/org/ayatana/NotificationItem/steam), IconName + IconThemePath (a PNG), no Activate method (a call
#            gets UnknownMethod), a dbusmenu menu; Steam's entries
#   discord  as Electron registers (Discord): its own name org.kde.StatusNotifierItem-PID-1, /StatusNotifierItem,
#            IconPixmap (ARGB32, network order, 16 and 32 px), Activate, ItemIsMenu false, a dbusmenu at /MenuBar
# Usage: sni-items.py ICONDIR LOG   (ICONDIR: steam_tray_mono.png, discord16.png, discord32.png: 8-bit RGBA PNGs,
# filter 0, as raster::png writes them). Every call an item gets is a line in LOG. Commands on stdin, one a line:
#   status ITEM STATUS     NewStatus (Active, Passive, NeedsAttention)
#   title ITEM TITLE       the title changes (NewTitle)
#   menu ITEM LABEL...     the menu's entries change (LayoutUpdated); "-" is a separator
#   quit ITEM              the app goes: its connection closes
# It prints "ready" once both items are registered with the watcher, and "ok" after each command.
import os, struct, sys, threading, zlib
import gi
gi.require_version('Gio', '2.0')
from gi.repository import Gio, GLib

ICONS, LOG = sys.argv[1], sys.argv[2]
ADDR = os.environ['DBUS_SESSION_BUS_ADDRESS']


def log(line):
    with open(LOG, 'a') as f:
        f.write(line + '\n')


def png_rgba(path):
    """our own PNGs: 8-bit RGBA, every row filter 0"""
    d = open(path, 'rb').read()
    at, idat, w, h = 8, b'', 0, 0
    while at < len(d):
        n, t = struct.unpack('>I4s', d[at:at + 8])
        body = d[at + 8:at + 8 + n]
        if t == b'IHDR':
            w, h = struct.unpack('>II', body[:8])
        elif t == b'IDAT':
            idat += body
        at += 12 + n
    raw = zlib.decompress(idat)
    rows = [raw[y * (w * 4 + 1) + 1:(y + 1) * (w * 4 + 1)] for y in range(h)]
    return w, h, b''.join(rows)


def argb(path):
    w, h, px = png_rgba(path)
    out = bytearray()
    for i in range(0, len(px), 4):
        r, g, b, a = px[i:i + 4]
        out += bytes((a, r, g, b))
    return (w, h, bytes(out))


ITEM_XML = '''<node><interface name="org.kde.StatusNotifierItem">
<property name="Category" type="s" access="read"/><property name="Id" type="s" access="read"/>
<property name="Title" type="s" access="read"/><property name="Status" type="s" access="read"/>
<property name="WindowId" type="i" access="read"/><property name="IconName" type="s" access="read"/>
<property name="IconThemePath" type="s" access="read"/><property name="IconPixmap" type="a(iiay)" access="read"/>
<property name="AttentionIconName" type="s" access="read"/><property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
<property name="ItemIsMenu" type="b" access="read"/><property name="Menu" type="o" access="read"/>
%s
<method name="ContextMenu"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
<method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
<method name="Scroll"><arg type="i" direction="in"/><arg type="s" direction="in"/></method>
<signal name="NewTitle"/><signal name="NewIcon"/><signal name="NewStatus"><arg type="s"/></signal>
</interface></node>'''
ACTIVATE = '<method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>'
MENU_XML = '''<node><interface name="com.canonical.dbusmenu">
<property name="Version" type="u" access="read"/><property name="Status" type="s" access="read"/>
<method name="GetLayout"><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/>
<arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/></method>
<method name="Event"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/><arg type="u" direction="in"/></method>
<method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
<signal name="LayoutUpdated"><arg type="u"/><arg type="i"/></signal>
</interface></node>'''


class Item:
    def __init__(self, name, props, menu, activate, own_name=None, path='/StatusNotifierItem', menu_path='/MenuBar'):
        self.name, self.props, self.menu, self.path, self.menu_path = name, props, menu, path, menu_path
        self.revision = 1
        self.conn = Gio.DBusConnection.new_for_address_sync(
            ADDR, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
        info = Gio.DBusNodeInfo.new_for_xml(ITEM_XML % (ACTIVATE if activate else '')).interfaces[0]
        self.conn.register_object(path, info, self.call, self.get, None)
        minfo = Gio.DBusNodeInfo.new_for_xml(MENU_XML).interfaces[0]
        self.conn.register_object(menu_path, minfo, self.menu_call, self.menu_get, None)
        if own_name:
            self.conn.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'RequestName',
                                GLib.Variant('(su)', (own_name, 4)), None, 0, -1, None)
        self.register_as = own_name or path

    def register(self):
        self.conn.call_sync('org.kde.StatusNotifierWatcher', '/StatusNotifierWatcher', 'org.kde.StatusNotifierWatcher',
                            'RegisterStatusNotifierItem', GLib.Variant('(s)', (self.register_as,)), None, 0, -1, None)

    def get(self, conn, sender, path, iface, prop):
        sig, val = self.props[prop]
        return GLib.Variant(sig, val)

    def call(self, conn, sender, path, iface, method, params, inv):
        log(f'{self.name} {method} {" ".join(str(p) for p in params.unpack())}')
        inv.return_value(None)

    def layout(self):
        # a label: "-" a separator, "!X" greyed out, "*X" a checkmark that is on, "+X" one that is off,
        # "NAME>A|B|..." a submenu (its items radio items, "*" the one on); ids count on through the submenus
        n = [0]

        def node(label, radio=False):
            n[0] += 1
            k = n[0]
            kids = []
            if label == '-':
                p = {'type': GLib.Variant('s', 'separator')}
            elif '>' in label:
                name, sub = label.split('>', 1)
                p = {'label': GLib.Variant('s', name), 'children-display': GLib.Variant('s', 'submenu')}
                kids = [node(x, True) for x in sub.split('|')]
            else:
                p = {}
                if label[:1] in '!*+' and label[:1]:
                    mark, label = label[0], label[1:]
                    if mark == '!':
                        p['enabled'] = GLib.Variant('b', False)
                    else:
                        p['toggle-type'] = GLib.Variant('s', 'checkmark')
                        p['toggle-state'] = GLib.Variant('i', 1 if mark == '*' else 0)
                elif radio:
                    p['toggle-type'] = GLib.Variant('s', 'radio')
                    p['toggle-state'] = GLib.Variant('i', 0)
                if radio and 'toggle-type' in p:
                    p['toggle-type'] = GLib.Variant('s', 'radio')
                p['label'] = GLib.Variant('s', label)
            return GLib.Variant('(ia{sv}av)', (k, p, kids))
        kids = [node(x) for x in self.menu]
        return (self.revision, (0, {'children-display': GLib.Variant('s', 'submenu')}, kids))

    def menu_get(self, conn, sender, path, iface, prop):
        return GLib.Variant('u', 3) if prop == 'Version' else GLib.Variant('s', 'normal')

    def menu_call(self, conn, sender, path, iface, method, params, inv):
        args = params.unpack()
        if method == 'GetLayout':
            inv.return_value(GLib.Variant('(u(ia{sv}av))', self.layout()))
            return
        if method == 'AboutToShow':
            inv.return_value(GLib.Variant('(b)', (False,)))
            return
        if method == 'Event':
            log(f'{self.name} Event {args[0]} {args[1]}')
            inv.return_value(None)
            return

    def emit(self, signal, params=None, path=None, iface='org.kde.StatusNotifierItem'):
        self.conn.emit_signal(None, path or self.path, iface, signal, params)


def main():
    discord16, discord32 = argb(os.path.join(ICONS, 'discord16.png')), argb(os.path.join(ICONS, 'discord32.png'))
    steam = Item('steam', {
        'Category': ('s', 'ApplicationStatus'), 'Id': ('s', 'steam'), 'Title': ('s', 'Steam'), 'Status': ('s', 'Active'),
        'WindowId': ('i', 0), 'IconName': ('s', 'steam_tray_mono'), 'IconThemePath': ('s', ICONS), 'IconPixmap': ('a(iiay)', []),
        'AttentionIconName': ('s', ''), 'ToolTip': ('(sa(iiay)ss)', ('', [], '', '')), 'ItemIsMenu': ('b', False),
        'Menu': ('o', '/org/ayatana/NotificationItem/steam/Menu')},
        ['Store', 'Library', 'Community', 'Friends', 'Screenshots', 'Settings', 'Big Picture', '-', 'Exit Steam'],
        activate=False, path='/org/ayatana/NotificationItem/steam', menu_path='/org/ayatana/NotificationItem/steam/Menu')
    discord = Item('discord', {
        'Category': ('s', 'ApplicationStatus'), 'Id': ('s', 'discord'), 'Title': ('s', 'Discord'), 'Status': ('s', 'Active'),
        'WindowId': ('i', 0), 'IconName': ('s', ''), 'IconThemePath': ('s', ''), 'IconPixmap': ('a(iiay)', [discord32, discord16]),
        'AttentionIconName': ('s', ''), 'ToolTip': ('(sa(iiay)ss)', ('', [], '', '')), 'ItemIsMenu': ('b', False),
        'Menu': ('o', '/MenuBar')},
        ['Open Discord', 'Check for Updates…', '!Acknowledgements', '-', 'Quit Discord'],
        activate=True, own_name=f'org.kde.StatusNotifierItem-{os.getpid()}-1')
    items = {'steam': steam, 'discord': discord}
    steam.register()
    discord.register()
    print('ready', flush=True)
    loop = GLib.MainLoop()

    def command(line):
        w = line.split()
        if not w:
            return
        it = items.get(w[1]) if len(w) > 1 else None
        if w[0] == 'status':
            it.props['Status'] = ('s', w[2])
            it.emit('NewStatus', GLib.Variant('(s)', (w[2],)))
        elif w[0] == 'title':
            it.props['Title'] = ('s', ' '.join(w[2:]))
            it.emit('NewTitle')
        elif w[0] == 'menu':
            it.menu = ' '.join(w[2:]).split(',')
            it.revision += 1
            it.emit('LayoutUpdated', GLib.Variant('(ui)', (it.revision, 0)), path=it.menu_path, iface='com.canonical.dbusmenu')
        elif w[0] == 'add' and w[1] not in items:
            # an app whose picture cannot be read: its IconName is a damaged PNG in its IconThemePath
            with open(os.path.join(ICONS, 'damaged.png'), 'wb') as f:
                f.write(b'\x89PNG\r\n\x1a\n' + b'\0' * 40)
            it = Item(w[1], {
                'Category': ('s', 'ApplicationStatus'), 'Id': ('s', w[1]), 'Title': ('s', w[1].title()), 'Status': ('s', 'Active'),
                'WindowId': ('i', 0), 'IconName': ('s', 'damaged'), 'IconThemePath': ('s', ICONS), 'IconPixmap': ('a(iiay)', []),
                'AttentionIconName': ('s', ''), 'ToolTip': ('(sa(iiay)ss)', ('', [], '', '')), 'ItemIsMenu': ('b', False),
                'Menu': ('o', '/MenuBar')}, ['Quit'], activate=True, own_name=f'org.kde.StatusNotifierItem-{os.getpid()}-{len(items) + 1}')
            items[w[1]] = it
            it.register()
        elif w[0] == 'quit':
            it.conn.close_sync(None)
        it.conn.flush_sync(None) if not it.conn.is_closed() else None
        print('ok', flush=True)

    def reader():
        for line in sys.stdin:
            GLib.idle_add(lambda l=line: (command(l.strip()), False)[1])
        GLib.idle_add(loop.quit)
    threading.Thread(target=reader, daemon=True).start()
    loop.run()


if __name__ == '__main__':
    main()
