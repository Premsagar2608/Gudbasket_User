import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'product_list_screen.dart';
import 'package:flutter/foundation.dart' show kIsWeb; // add at top with other imports
class CheckoutPage extends StatefulWidget {
  final List<Map<String, dynamic>> cartItems;
  final int totalAmount;
  final String city;
  final String shopId;

  const CheckoutPage({
    super.key,
    required this.cartItems,
    required this.totalAmount,
    required this.city,
    required this.shopId,
  });

  @override
  State<CheckoutPage> createState() => _CheckoutPageState();
}

class _CheckoutPageState extends State<CheckoutPage> {
  final dbRef = FirebaseDatabase.instance.ref();
  final user = FirebaseAuth.instance.currentUser;

  final nameController = TextEditingController();
  final phoneController = TextEditingController();
  final houseController = TextEditingController();
  final streetController = TextEditingController();
  final landmarkController = TextEditingController();
  final cityController = TextEditingController();
  final pinCodeController = TextEditingController();

  Position? currentPosition;
  double deliveryRate = 0;
  int minOrderValue = 0;
  double deliveryCharge = 0;
  double distanceInKm = 0;
  int finalTotal = 0;
  bool locationSelected = false;
  double shopLat = 0;
  double shopLng = 0;

  @override
  void initState() {
    super.initState();
    _loadSavedAddress();
    _fetchShopInfo();
  }

  Future<void> _fetchShopInfo() async {
    final snapshot = await dbRef
        .child("cities/${widget.city}/shops/${widget.shopId}")
        .get();

    if (snapshot.exists) {
      final data = snapshot.value as Map<dynamic, dynamic>;
      setState(() {
        deliveryRate = (data['deliveryRate'] ?? 0).toDouble();
        minOrderValue = (data['minOrderValue'] ?? 0).toInt();

        final loc = data['location'] as Map<dynamic, dynamic>? ?? {};
        shopLat = (loc['latitude'] ?? 0).toDouble();
        shopLng = (loc['longitude'] ?? 0).toDouble();
      });
    }
  }

  Future<void> _loadSavedAddress() async {
    final prefs = await SharedPreferences.getInstance();
    nameController.text = prefs.getString('name') ?? '';
    phoneController.text = prefs.getString('phone') ?? '';
    houseController.text = prefs.getString('house') ?? '';
    streetController.text = prefs.getString('street') ?? '';
    landmarkController.text = prefs.getString('landmark') ?? '';
    cityController.text = prefs.getString('city') ?? '';
    pinCodeController.text = prefs.getString('pinCode') ?? '';
  }

  Future<void> _saveAddressLocally() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('name', nameController.text);
    await prefs.setString('phone', phoneController.text);
    await prefs.setString('house', houseController.text);
    await prefs.setString('street', streetController.text);
    await prefs.setString('landmark', landmarkController.text);
    await prefs.setString('city', cityController.text);
    await prefs.setString('pinCode', pinCodeController.text);
  }


 // import 'package:flutter/foundation.dart' show kIsWeb; // add at top with other imports

  Future<void> _fetchLocationAndDecode() async {
    // show progress
    showDialog(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      // 1) Permissions
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled && !kIsWeb) {
        throw 'Location services are disabled.';
      }

      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        throw 'Location permission denied.';
      }

      // 2) Get current position (this throws on failure; never returns null)
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      // 3) Reverse geocode (guarded)
      List<Placemark> placemarks = const [];
      try {
        placemarks = await placemarkFromCoordinates(pos.latitude, pos.longitude);
      } catch (_) {
        // Geocoding can fail on web without proper backend — ignore, we’ll still proceed.
      }

      // 4) Distance & delivery (guard shop coords)
      final hasShopCoords = shopLat != 0 && shopLng != 0;
      final km = hasShopCoords
          ? Geolocator.distanceBetween(pos.latitude, pos.longitude, shopLat, shopLng) / 1000
          : 0.0;

      final charge = (widget.totalAmount >= minOrderValue)
          ? 0.0
          : (hasShopCoords ? (km * deliveryRate) : 0.0);

      // 5) Update state safely
      if (!mounted) return;
      setState(() {
        currentPosition = pos;
        distanceInKm = km;
        deliveryCharge = charge;
        finalTotal = widget.totalAmount + charge.round();
        locationSelected = true;

        if (placemarks.isNotEmpty) {
          final p = placemarks.first;
          // Use null-aware fallbacks so we never assign null
          houseController.text = p.subThoroughfare ?? houseController.text;
          streetController.text = p.thoroughfare ?? streetController.text;
          landmarkController.text = p.subLocality ?? landmarkController.text;
          cityController.text = p.locality ?? cityController.text;
          pinCodeController.text = p.postalCode ?? pinCodeController.text;
        }
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Location fetch failed: $e')),
      );
    } finally {
      if (mounted) {
        // Always close the progress dialog from the root navigator
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }






  bool _anyFieldEmpty() {
    return nameController.text.trim().isEmpty ||
        phoneController.text.trim().isEmpty ||
        houseController.text.trim().isEmpty ||
        streetController.text.trim().isEmpty ||
        landmarkController.text.trim().isEmpty ||
        cityController.text.trim().isEmpty ||
        pinCodeController.text.trim().isEmpty;
  }

  Future<void> _placeOrder() async {
    if (user == null) return;

    if (!locationSelected || currentPosition == null) {
      _showError("Please select location first.");
      return;
    }
    if (_anyFieldEmpty()) {
      _showError("Please fill all the fields before placing the order.");
      return;
    }

    await _saveAddressLocally();

    final orderId = DateTime.now().millisecondsSinceEpoch.toString();
    final now = DateTime.now().toIso8601String();

    final orderData = {
      "userId": user!.uid,
      "name": nameController.text,
      "phone": phoneController.text,
      "address": {
        "house": houseController.text,
        "street": streetController.text,
        "landmark": landmarkController.text,
        "city": cityController.text,
        "pinCode": pinCodeController.text,
      },
      "location": {
        "lat": currentPosition!.latitude,
        "lng": currentPosition!.longitude,
      },
      "status": "ordered",
      "timestamp": now,
      "total": finalTotal,
      "itemTotal": widget.totalAmount,
      "deliveryCharge": deliveryCharge.round(),
      "handlingFee": 0,
      "items": widget.cartItems,
    };

    try {
      await dbRef
          .child(
          "cities/${widget.city}/shops/${widget.shopId}/orders/$orderId")
          .set(orderData);

      await dbRef
          .child("users/${user!.uid}/orders/$orderId")
          .set(orderData);

      final revenueRef = dbRef
          .child("cities/${widget.city}/shops/${widget.shopId}/totalRevenue");
      await revenueRef.runTransaction((Object? current) {
        final curr = (current as int?) ?? 0;
        return Transaction.success(curr + 1);
      });

      for (final item in widget.cartItems) {
        final String prodKey = (item["key"] ?? "").toString();
        if (prodKey.isEmpty) continue;

        final String shopForItem =
        (item["shopId"] ?? widget.shopId).toString();
        final int qty =
        (item["quantity"] is num) ? (item["quantity"] as num).toInt() : 1;

        final stockRef = dbRef.child(
            "cities/${widget.city}/shops/$shopForItem/products/$prodKey/stock");

        await stockRef.runTransaction((Object? current) {
          final curr = (current as int?) ?? 0;
          final next = curr - qty;
          return Transaction.success(next < 0 ? 0 : next);
        });
      }

      for (final item in widget.cartItems) {
        final key = (item["key"] ?? "").toString();
        if (key.isEmpty) continue;
        await dbRef.child("users/${user!.uid}/cart/$key").remove();
      }

      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.green,
                ),
                padding: const EdgeInsets.all(16),
                child: const Icon(Icons.check,
                    size: 48, color: Colors.white),
              ),
              const SizedBox(height: 16),
              const Text(
                "Order Placed Successfully!",
                style:
                TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.pop(context);
                  Navigator.pushReplacementNamed(
                      context, '/orders_screen');
                },
                child: const Text("Ordered Successfully"),
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      _showError("Failed to place order: $e");
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  int _remainingForFreeDelivery() {
    if (minOrderValue <= 0) return 0;
    final remaining = minOrderValue - widget.totalAmount;
    return remaining > 0 ? remaining : 0;
  }

  Widget _freeDeliveryButton() {
    final remaining = _remainingForFreeDelivery();
    if (remaining <= 0) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 12.0, bottom: 8.0),
      child: ElevatedButton.icon(
        icon: const Icon(Icons.add_shopping_cart),
        label: Text("Add items worth ₹$remaining to get free delivery"),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.green,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ProductListScreen(
                city: widget.city,
                shopId: widget.shopId,
                shopName: "Shop", // replace with actual shop name if available
              ),
            ),
          );
        },
      ),
    );
  }


  Widget _buildInput(String label, TextEditingController controller,
      [TextInputType type = TextInputType.text]) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: controller,
        keyboardType: type,
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
        ).copyWith(labelText: label),
      ),
    );
  }

  Widget _billRow(String label, String value,
      {bool isBold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 14,
                  fontWeight:
                  isBold ? FontWeight.bold : FontWeight.normal)),
          Text(value,
              style: TextStyle(
                  fontSize: 14,
                  fontWeight:
                  isBold ? FontWeight.bold : FontWeight.normal)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Checkout")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            if (locationSelected)
              Card(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                elevation: 3,
                margin: const EdgeInsets.only(bottom: 20),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("Bill Summary",
                          style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold)),
                      const Divider(height: 20),
                      _billRow("Item Total", "₹${widget.totalAmount}"),
                      _billRow("Delivery Charge",
                          "₹${deliveryCharge.round()}"),
                      const SizedBox(height: 10),
                      _billRow("Final Total", "₹$finalTotal",
                          isBold: true),
                      const SizedBox(height: 20),
                      ElevatedButton(
                        onPressed: _placeOrder,
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 40, vertical: 14),
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          textStyle: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold),
                        ),
                        child: const Text("Place Order"),
                      ),
                    ],
                  ),
                ),
              ),
            ElevatedButton.icon(
              onPressed: _fetchLocationAndDecode,
              icon: const Icon(Icons.my_location),
              label: const Text("Use Current Location"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueGrey,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 12),
              ),
            ),
            _freeDeliveryButton(),
            const SizedBox(height: 20),
            Card(
              elevation: 3,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    const Text("Delivery Address",
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 10),
                    _buildInput("Name", nameController),
                    _buildInput("Phone Number", phoneController,
                        TextInputType.phone),
                    _buildInput("House No.", houseController),
                    _buildInput("Street", streetController),
                    _buildInput("Landmark", landmarkController),
                    _buildInput("City", cityController),
                    _buildInput("Pin Code", pinCodeController,
                        TextInputType.number),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }
}
