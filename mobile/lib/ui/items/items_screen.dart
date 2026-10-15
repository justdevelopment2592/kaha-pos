import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';
import 'item_form_screen.dart';

class ItemsScreen extends ConsumerStatefulWidget {
  const ItemsScreen({super.key, required this.profile});
  final Profile profile;
  @override
  ConsumerState<ItemsScreen> createState() => _ItemsScreenState();
}

class _ItemsScreenState extends ConsumerState<ItemsScreen> {
  String _query = '';
  bool _showArchived = false;

  Future<void> _openForm({CatalogItem? item}) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ItemFormScreen(profile: widget.profile, item: item)),
    );
    if (changed == true) ref.invalidate(catalogProvider);
  }

  Future<void> _receive(CatalogItem item) async {
    final branch = ref.read(selectedBranchProvider);
    if (branch == null) return;
    final qty = TextEditingController();
    final refText = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Receive ${item.name}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('At ${branch.name}', style: TextStyle(color: Theme.of(ctx).colorScheme.outline)),
          const SizedBox(height: 12),
          TextField(controller: qty, keyboardType: TextInputType.number, autofocus: true, decoration: const InputDecoration(labelText: 'Quantity received')),
          const SizedBox(height: 12),
          TextField(controller: refText, decoration: const InputDecoration(labelText: 'Delivery reference (optional)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Receive stock')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final n = int.tryParse(qty.text.trim());
    if (n == null || n <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a whole number above zero.')));
      return;
    }
    final done = await runAction(
      context,
      () => ref.read(repositoryProvider).receiveStock(branchId: branch.id, variantId: item.variantId, qty: n, reference: refText.text.trim()),
      success: 'Received $n',
    );
    if (done) ref.invalidate(catalogProvider);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    final catalog = ref.watch(catalogProvider);
    final branch = ref.watch(selectedBranchProvider);
    final canEdit = p.can(Perm.catalog);
    final canReceive = p.can(Perm.stockReceive);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Items'),
        actions: [
          if (p.branches.length > 1)
            PopupMenuButton<Branch>(
              tooltip: 'Branch',
              initialValue: branch,
              onSelected: (b) => ref.read(selectedBranchProvider.notifier).state = b,
              itemBuilder: (_) => [for (final b in p.branches) PopupMenuItem(value: b, child: Text(b.name))],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(children: [Text(branch?.name ?? ''), const Icon(Icons.arrow_drop_down)]),
              ),
            ),
          IconButton(tooltip: 'Refresh', onPressed: () => ref.invalidate(catalogProvider), icon: const Icon(Icons.refresh)),
        ],
      ),
      floatingActionButton: canEdit
          ? FloatingActionButton.extended(onPressed: () => _openForm(), icon: const Icon(Icons.add), label: const Text('Add item'))
          : null,
      body: catalog.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorPanel(message: friendlyError(e), onRetry: () => ref.invalidate(catalogProvider)),
        data: (c) {
          final q = _query.toLowerCase();
          final rows = c.items
              .where((i) => _showArchived || !i.archived)
              .where((i) => q.isEmpty || i.name.toLowerCase().contains(q) || i.sku.toLowerCase().contains(q) || i.barcodes.any((b) => b.contains(q)))
              .toList();
          final taxById = {for (final t in c.taxCodes) t.id: t};
          return Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: TextField(
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search name, SKU or barcode'),
                onChanged: (v) => setState(() => _query = v.trim()),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                Text('${rows.length} item${rows.length == 1 ? '' : 's'}', style: TextStyle(color: Theme.of(context).colorScheme.outline)),
                const Spacer(),
                FilterChip(label: const Text('Show archived'), selected: _showArchived, onSelected: (v) => setState(() => _showArchived = v)),
              ]),
            ),
            Expanded(
              child: rows.isEmpty
                  ? EmptyPanel(
                      title: c.items.isEmpty ? 'No items yet' : 'No match',
                      body: c.items.isEmpty
                          ? (canEdit ? 'Tap Add item to put your first product on sale.' : 'Ask an owner or manager to add items.')
                          : 'Try another name, SKU or barcode.',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                      itemCount: rows.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, i) {
                        final it = rows[i];
                        final stock = it.stock;
                        final tax = taxById[it.taxCodeId];
                        return Card(
                          child: ListTile(
                            onTap: canEdit ? () => _openForm(item: it) : null,
                            title: Text(it.name, style: TextStyle(decoration: it.archived ? TextDecoration.lineThrough : null)),
                            subtitle: Text([
                              it.sku,
                              if (tax != null && tax.treatment != 'vatable') tax.name,
                              if (stock != null) '${stock.toInt()} on hand',
                              if (it.archived) 'Archived',
                            ].join(', ')),
                            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                              Text(formatPeso(it.priceCentavos), style: const TextStyle(fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
                              if (canReceive && !it.archived)
                                IconButton(tooltip: 'Receive stock', onPressed: () => _receive(it), icon: const Icon(Icons.move_to_inbox_outlined)),
                            ]),
                            leading: stock != null && stock <= 5
                                ? const CircleAvatar(backgroundColor: KahaColors.warnWash, child: Icon(Icons.warning_amber, color: KahaColors.warn))
                                : null,
                          ),
                        );
                      },
                    ),
            ),
          ]);
        },
      ),
    );
  }
}
