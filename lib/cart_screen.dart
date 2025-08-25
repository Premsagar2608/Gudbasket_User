import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:shimmer/shimmer.dart';
import 'checkoutscreen.dart';

class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  final user = FirebaseAuth.instance.currentUser;
  final dbRef = FirebaseDatabase.instance.ref();

  List<Map<String, dynamic>> cartItems = [];
  bool isLoading = true;

  // Shop key -> display name (key format: "$city|$shopId")
  final Map<String, String> _shopNames = {};

  static const double handlingFee = 10.0;

  @override
  void initState() {
    super.initState();
    if (user != null) fetchCartItems();
  }

  // ---------------------------- DATA LOADING ----------------------------

  Future<void> fetchCartItems() async {
    setState(() => isLoading = true);

    final snapshot = await dbRef.child("users/${user!.uid}/cart").get();
    final List<Map<String, dynamic>> loaded = [];

    for (var item in snapshot.children) {
      final data = Map<String, dynamic>.from(item.value as Map);
      data["key"] = item.key;
      data["shopId"] = (data["shopId"] ?? item.child("shopId").value ?? "").toString();
      data["city"] = (data["city"] ?? item.child("city").value ?? "").toString();
      loaded.add(data);
    }

    cartItems = loaded;

    // fetch shop names for all distinct shop groups
    final shopKeys = <String>{};
    for (final it in cartItems) {
      final city = (it["city"] ?? "").toString();
      final shopId = (it["shopId"] ?? "").toString();
      if (city.isNotEmpty && shopId.isNotEmpty) {
        shopKeys.add("$city|$shopId");
      }
    }
    await _fetchShopNames(shopKeys);

    if (mounted) {
      setState(() => isLoading = false);
    }
  }

  Future<void> _fetchShopNames(Set<String> shopKeys) async {
    final futures = <Future<void>>[];
    for (final key in shopKeys) {
      if (_shopNames.containsKey(key)) continue; // already fetched
      final parts = key.split('|');
      if (parts.length != 2) continue;
      final city = parts[0];
      final shopId = parts[1];

      futures.add(() async {
        try {
          final snap = await dbRef.child("cities/$city/shops/$shopId").get();
          String name = "Shop $shopId";
          if (snap.exists) {
            final data = Map<String, dynamic>.from(snap.value as Map);
            // try common naming fields
            name = (data["name"] ??
                data["shopName"] ??
                data["title"] ??
                name)
                .toString();
          }
          _shopNames[key] = name;
        } catch (_) {
          _shopNames[key] = "Shop $shopId";
        }
      }());
    }
    if (futures.isNotEmpty) {
      await Future.wait(futures);
    }
  }

  // ---------------------------- HELPERS ----------------------------

  void updateQuantityLocal(String key, int newQty) async {
    if (newQty < 1) return;
    final index = cartItems.indexWhere((item) => item["key"] == key);
    if (index == -1) return;

    setState(() {
      cartItems[index]["quantity"] = newQty;
    });

    await dbRef.child("users/${user!.uid}/cart/$key/quantity").set(newQty);
  }

  Future<void> removeItem(String key) async {
    await dbRef.child("users/${user!.uid}/cart/$key").remove();
    await fetchCartItems();
  }

  Future<void> removeShopItems(String city, String shopId) async {
    if (user == null) return;

    // Build a multi-path update to delete all items from this shop at once
    final Map<String, Object?> updates = {};
    for (final it in cartItems) {
      if ((it["city"] ?? "") == city && (it["shopId"] ?? "") == shopId) {
        final k = (it["key"] ?? "").toString();
        if (k.isNotEmpty) {
          updates["users/${user!.uid}/cart/$k"] = null;
        }
      }
    }
    if (updates.isEmpty) return;

    await dbRef.update(updates);
    await fetchCartItems();
  }

  // Enforce single shop for checkout
  bool _allItemsFromSameShop() {
    if (cartItems.isEmpty) return false;
    final firstShop = (cartItems.first["shopId"] ?? "").toString();
    final firstCity = (cartItems.first["city"] ?? "").toString();
    if (firstShop.isEmpty || firstCity.isEmpty) return false;

    for (final item in cartItems) {
      final s = (item["shopId"] ?? "").toString();
      final c = (item["city"] ?? "").toString();
      if (s != firstShop || c != firstCity) return false;
    }
    return true;
  }

  Future<void> _showMultiShopDialog() async {
    return showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text("Multiple Shops Detected"),
        content: const Text(
          "Your cart has items from different shops.\n\n"
              "Please checkout one shop at a time. You can remove other shops' items with the delete button in each shop section.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("OK"),
          ),
        ],
      ),
    );
  }

  void navigateToCheckout(double totalPrice) {
    if (cartItems.isEmpty) return;

    if (!_allItemsFromSameShop()) {
      _showMultiShopDialog();
      return;
    }

    final shopId = cartItems[0]["shopId"];
    final city = cartItems[0]["city"];

    totalPrice = cartItems.fold(0.0, (sum, item) {
      final itemPrice = (item['price'] ?? 0);
      final qty = (item['quantity'] ?? 1);
      final p = (itemPrice is num ? itemPrice : 0).toDouble();
      final q = (qty is num ? qty : 1).toDouble();
      return sum + (p * q);
    });

    if (shopId != null && city != null && shopId != "" && city != "") {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CheckoutPage(
            cartItems: cartItems,
            totalAmount: totalPrice.toInt() + handlingFee.toInt(),
            shopId: shopId,
            city: city,
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Invalid cart items. Cannot proceed to checkout.")),
      );
    }
  }

  // Group cart items by (city, shopId)
  Map<String, List<Map<String, dynamic>>> _groupByShop() {
    final Map<String, List<Map<String, dynamic>>> groups = {};
    for (final it in cartItems) {
      final city = (it["city"] ?? "").toString();
      final shopId = (it["shopId"] ?? "").toString();
      final key = "$city|$shopId";
      groups.putIfAbsent(key, () => []);
      groups[key]!.add(it);
    }
    return groups;
  }

  String _shopDisplayName(String shopKey) {
    return _shopNames[shopKey] ?? "Shop";
  }

  // ---------------------------- UI ----------------------------

  @override
  Widget build(BuildContext context) {
    // Cart totals
    double subtotal = 0, totalMrp = 0;
    for (var item in cartItems) {
      final price = (item["price"] ?? 0);
      final qty = (item["quantity"] ?? 1);
      final mrp = (item["mrp"] ?? 0);
      subtotal += (price is num ? price : 0) * (qty is num ? qty : 1);
      totalMrp += (mrp is num ? mrp : 0) * (qty is num ? qty : 1);
    }

    final totalWithFee = subtotal + handlingFee;
    final savings = totalMrp - subtotal;

    final grouped = _groupByShop();
    final shopKeysInOrder = grouped.keys.toList(); // order as found

    return Scaffold(
      appBar: AppBar(title: const Text("Your Cart")),
      body: user == null
          ? const Center(child: Text("Please log in to view your cart."))
          : isLoading
          ? ListView.builder(
        itemCount: 4,
        itemBuilder: (_, i) => Shimmer.fromColors(
          baseColor: Colors.grey[300]!,
          highlightColor: Colors.grey[100]!,
          child: Card(
            margin: const EdgeInsets.all(8),
            child: const ListTile(
              leading: SizedBox(width: 50, height: 50),
              title: SizedBox(height: 12),
              subtitle: SizedBox(height: 12, width: double.infinity),
            ),
          ),
        ),
      )
          : cartItems.isEmpty
          ? const Center(child: Text("Your cart is empty."))
          : Column(
        children: [
          // ---- GROUPED LIST BY SHOP ----
          Expanded(
            child: ListView.builder(
              itemCount: shopKeysInOrder.length,
              itemBuilder: (_, idx) {
                final shopKey = shopKeysInOrder[idx];
                final parts = shopKey.split('|');
                final city = parts.isNotEmpty ? parts[0] : "";
                final shopId = parts.length > 1 ? parts[1] : "";
                final items = grouped[shopKey] ?? [];

                return Card(
                  margin: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 8),
                  elevation: 2,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Section header with shop name + delete all button
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _shopDisplayName(shopKey),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            TextButton.icon(
                              onPressed: () => removeShopItems(city, shopId),
                              icon: const Icon(Icons.delete_outline, color: Colors.red),
                              label: const Text(
                                "Remove all",
                                style: TextStyle(color: Colors.red),
                              ),
                            ),
                          ],
                        ),
                        const Divider(),

                        // Items for this shop
                        ...items.map((item) {
                          final hasImage = (item["image"] ?? "").toString().isNotEmpty;
                          final mrpVal = (item["mrp"] ?? 0);
                          final priceVal = (item["price"] ?? 0);
                          final showMrpStrike =
                              (mrpVal is num ? mrpVal : 0) >
                                  (priceVal is num ? priceVal : 0);

                          return Container(
                            margin: const EdgeInsets.symmetric(vertical: 6),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey.shade300),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: hasImage
                                      ? Image.network(
                                    item["image"],
                                    width: 60,
                                    height: 60,
                                    fit: BoxFit.cover,
                                  )
                                      : const Icon(Icons.image_not_supported, size: 60),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        item["name"] ?? "",
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontWeight: FontWeight.bold),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(item["unit"] ?? "", style: const TextStyle(fontSize: 12)),
                                      const SizedBox(height: 6),
                                      Row(
                                        children: [
                                          Text("₹${priceVal is num ? priceVal : 0} x ${item["quantity"] ?? 1}"),
                                          const SizedBox(width: 8),
                                          if (showMrpStrike)
                                            Text(
                                              "₹${mrpVal is num ? mrpVal : 0}",
                                              style: const TextStyle(
                                                fontSize: 12,
                                                decoration: TextDecoration.lineThrough,
                                                color: Colors.grey,
                                              ),
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Row(
                                        children: [
                                          IconButton(
                                            icon: const Icon(Icons.remove_circle_outline),
                                            onPressed: () => updateQuantityLocal(
                                              item["key"],
                                              (item["quantity"] ?? 1) - 1,
                                            ),
                                          ),
                                          Text("${item["quantity"] ?? 1}"),
                                          IconButton(
                                            icon: const Icon(Icons.add_circle_outline),
                                            onPressed: () => updateQuantityLocal(
                                              item["key"],
                                              (item["quantity"] ?? 1) + 1,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete, color: Colors.red),
                                  onPressed: () => removeItem(item["key"]),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),

          // ---- SUMMARY + CHECKOUT ----
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text("Items: ${cartItems.length}", style: const TextStyle(fontSize: 14)),
                Text("Subtotal: ₹${subtotal.toStringAsFixed(2)}", style: const TextStyle(fontSize: 14)),
                Text("Handling Fee: ₹${handlingFee.toStringAsFixed(2)}",
                    style: const TextStyle(fontSize: 14)),
                Text(
                  "You Save: ₹${savings.toStringAsFixed(2)}",
                  style: const TextStyle(fontSize: 14, color: Colors.green),
                ),
                const Divider(thickness: 1, height: 20),
                Text(
                  "Total: ₹${totalWithFee.toStringAsFixed(2)}",
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: () => navigateToCheckout(subtotal),
                  child: const Text(
                    "Proceed to Checkout",
                    style: TextStyle(fontSize: 16, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
