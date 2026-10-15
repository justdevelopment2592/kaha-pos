import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/money.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';

/// Add or edit one sellable item. Prices include VAT for VATable items.
class ItemFormScreen extends ConsumerStatefulWidget {
  const ItemFormScreen({super.key, required this.profile, this.item});
  final Profile profile;
  final CatalogItem? item;
  @override
  ConsumerState<ItemFormScreen> createState() => _ItemFormScreenState();
}

class _ItemFormScreenState extends ConsumerState<ItemFormScreen> {
  late final _name = TextEditingController(text: widget.item?.name ?? '');
  late final _sku = TextEditingController(text: widget.item?.sku ?? '');
  late final _unit = TextEditingController(text: widget.item?.unit ?? 'pc');
  late final _price = TextEditingController(text: widget.item == null ? '' : pesoInputText(widget.item!.priceCentavos));
  final _barcodeInput = TextEditingController();
  final _openingQty = TextEditingController();
  late List<String> _barcodes = [...?widget.item?.barcodes];
  String? _taxCodeId;
  String? _categoryId;
  bool _busy = false;

  bool get _isNew => widget.item == null;

  @override
  void initState() {
    super.initState();
    _taxCodeId = widget.item?.taxCodeId;
    _categoryId = widget.item?.categoryId;
  }

  @override
  void dispose() {
    for (final c in [_name, _sku, _unit, _price, _barcodeInput, _openingQty]) {
      c.dispose();
    }
    super.dispose();
  }

  void _addBarcode() {
    final v = _barcodeInput.text.trim();
    if (v.isEmpty) return;
    if (!RegExp(r'^[0-9A-Za-z-]{4,32}$').hasMatch(v)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Barcodes are 4 to 32 letters or numbers.')));
      return;
    }
    setState(() {
      if (!_barcodes.contains(v)) _barcodes = [..._barcodes, v];
      _barcodeInput.clear();
    });
  }

  Future<void> _newCategory() async {
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New category'),
        content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(labelText: 'Name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Add category')),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final id = await ref.read(repositoryProvider).saveCategory(null, name);
      ref.invalidate(catalogProvider);
      setState(() => _categoryId = id);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  Future<void> _save() async {
    final price = parsePeso(_price.text);
    final sku = _sku.text.trim().toUpperCase();
    String? problem;
    if (_name.text.trim().isEmpty) {
      problem = 'Add a name.';
    } else if (!RegExp(r'^[A-Z0-9._-]{1,40}$').hasMatch(sku)) {
      problem = 'SKU can only use letters, numbers, dot and dash.';
    } else if (price == null) {
      problem = 'Enter a price like 85 or 85.50.';
    } else if (_taxCodeId == null) {
      problem = 'Pick a tax type.';
    }
    int? opening;
    if (problem == null && _isNew && _openingQty.text.trim().isNotEmpty) {
      opening = int.tryParse(_openingQty.text.trim());
      if (opening == null || opening <= 0) problem = 'Starting stock must be a whole number above zero.';
    }
    if (problem != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(problem)));
      return;
    }
    _addBarcode();
    setState(() => _busy = true);
    final repo = ref.read(repositoryProvider);
    final branch = ref.read(selectedBranchProvider);
    final ok = await runAction(context, () async {
      final id = await repo.saveItem(
        variantId: widget.item?.variantId,
        name: _name.text.trim(),
        sku: sku,
        unit: _unit.text.trim().isEmpty ? 'pc' : _unit.text.trim(),
        taxCodeId: _taxCodeId!,
        categoryId: _categoryId,
        priceCentavos: price!,
        barcodes: _barcodes,
      );
      if (opening != null && branch != null) {
        await repo.receiveStock(branchId: branch.id, variantId: id, qty: opening, reference: 'Opening stock');
      }
    }, success: _isNew ? 'Item added' : 'Item saved');
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  Future<void> _toggleArchive() async {
    final item = widget.item!;
    final ok = await runAction(
      context,
      () => ref.read(repositoryProvider).archiveItem(item.variantId, !item.archived),
      success: item.archived ? 'Item restored' : 'Item archived. It no longer appears at checkout.',
    );
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(catalogProvider).valueOrNull;
    final taxCodes = catalog?.taxCodes ?? const <TaxCode>[];
    final categories = catalog?.categories ?? const <Category>[];
    final canReceive = widget.profile.can(Perm.stockReceive);
    final branch = ref.watch(selectedBranchProvider);
    _taxCodeId ??= taxCodes.where((t) => t.code == 'V12').map((t) => t.id).firstOrNull;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'Add item' : 'Edit item'),
        actions: [
          if (!_isNew)
            TextButton(onPressed: _busy ? null : _toggleArchive, child: Text(widget.item!.archived ? 'Restore' : 'Archive')),
        ],
      ),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 32), children: [
          TextField(controller: _name, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'Item name', hintText: 'e.g. Pancit canton, calamansi 80g')),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(controller: _sku, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'SKU', hintText: 'NDL-001')),
            ),
            const SizedBox(width: 12),
            SizedBox(width: 110, child: TextField(controller: _unit, decoration: const InputDecoration(labelText: 'Unit', hintText: 'pc'))),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: _price,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Selling price', prefixText: '₱ ', helperText: 'Includes VAT for VATable items'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: taxCodes.any((t) => t.id == _taxCodeId) ? _taxCodeId : null,
            decoration: const InputDecoration(labelText: 'Tax type'),
            items: [for (final t in taxCodes) DropdownMenuItem(value: t.id, child: Text(t.name))],
            onChanged: (v) => setState(() => _taxCodeId = v),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String?>(
                value: categories.any((c) => c.id == _categoryId) ? _categoryId : null,
                decoration: const InputDecoration(labelText: 'Category'),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('None')),
                  for (final c in categories) DropdownMenuItem<String?>(value: c.id, child: Text(c.name)),
                ],
                onChanged: (v) => setState(() => _categoryId = v),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.outlined(tooltip: 'New category', onPressed: _newCategory, icon: const Icon(Icons.add)),
          ]),
          const SectionLabel('Barcodes'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final b in _barcodes)
              InputChip(label: Text(b), onDeleted: () => setState(() => _barcodes = _barcodes.where((x) => x != b).toList())),
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: _barcodeInput,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Add barcode',
              hintText: 'Type or scan',
              suffixIcon: IconButton(onPressed: _addBarcode, icon: const Icon(Icons.add_circle_outline)),
            ),
            onSubmitted: (_) => _addBarcode(),
          ),
          if (_isNew && canReceive && branch != null) ...[
            const SectionLabel('Starting stock'),
            TextField(
              controller: _openingQty,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: 'Quantity on the shelf at ${branch.name}', hintText: 'Leave empty if none yet'),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: _busy
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                : Text(_isNew ? 'Add item' : 'Save changes'),
          ),
        ]),
      ),
    );
  }
}
