import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../account/account_screen.dart';
import '../items/items_screen.dart';
import '../roles/roles_screen.dart';
import '../users/users_screen.dart';

class _Dest {
  const _Dest(this.label, this.icon, this.selectedIcon, this.builder);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget Function(Profile) builder;
}

/// Destinations appear only when the signed-in user's permissions allow them.
/// The server enforces the same rules on every call.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.profile});
  final Profile profile;
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  List<_Dest> _destinations(Profile p) => [
        _Dest('Items', Icons.inventory_2_outlined, Icons.inventory_2, (p) => ItemsScreen(profile: p)),
        if (p.can(Perm.staff)) _Dest('Users', Icons.group_outlined, Icons.group, (p) => UsersScreen(profile: p)),
        if (p.can(Perm.settings)) _Dest('Roles', Icons.admin_panel_settings_outlined, Icons.admin_panel_settings, (p) => RolesScreen(profile: p)),
        _Dest('Me', Icons.person_outline, Icons.person, (p) => AccountScreen(profile: p)),
      ];

  @override
  Widget build(BuildContext context) {
    final dests = _destinations(widget.profile);
    final index = _index.clamp(0, dests.length - 1);
    final body = dests[index].builder(widget.profile);
    final wide = MediaQuery.sizeOf(context).width >= 840;

    if (wide) {
      return Scaffold(
        body: SafeArea(
          child: Row(children: [
            NavigationRail(
              selectedIndex: index,
              onDestinationSelected: (i) => setState(() => _index = i),
              labelType: NavigationRailLabelType.all,
              destinations: [
                for (final d in dests) NavigationRailDestination(icon: Icon(d.icon), selectedIcon: Icon(d.selectedIcon), label: Text(d.label)),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: body),
          ]),
        ),
      );
    }
    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final d in dests) NavigationDestination(icon: Icon(d.icon), selectedIcon: Icon(d.selectedIcon), label: d.label),
        ],
      ),
    );
  }
}
