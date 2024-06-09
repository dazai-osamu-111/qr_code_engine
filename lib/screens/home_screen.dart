import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:qr_code_scanner/qr_code_scanner.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final GlobalKey qrKey = GlobalKey();
  Barcode? result;
  QRViewController? controller;
  String busNumber = ''; // Mã xe buýt
  int busId = 9; // ID xe buýt mặc định
  String driverName = ''; // Tên tài xế
  Timer? positionTimer;
  bool showSuccess = false;
  bool showError = false;

  @override
  void initState() {
    super.initState();
    _checkLocationPermission().then((_) {
      _fetchBusInformation(); // Gọi API ngay khi vào app sau khi có quyền
    }).catchError((error) {
      // Xử lý lỗi nếu quyền bị từ chối
      print(error);
    });
  }

  Future<void> _checkLocationPermission() async {
    bool serviceEnabled;
    LocationPermission permission;

    // Kiểm tra nếu dịch vụ vị trí được bật
    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return Future.error('Location services are disabled.');
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return Future.error('Location permissions are denied');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      return Future.error(
          'Location permissions are permanently denied, we cannot request permissions.');
    }
  }

  @override
  void reassemble() {
    super.reassemble();
    if (Platform.isAndroid) {
      controller?.pauseCamera();
    } else if (Platform.isIOS) {
      controller?.resumeCamera();
    }
  }

  @override
  void dispose() {
    controller?.dispose();
    positionTimer?.cancel();
    super.dispose();
  }

  void _onQRViewCreated(QRViewController controller) {
    this.controller = controller;
    controller.scannedDataStream.listen((scanData) async {
      setState(() {
        result = scanData;
      });
      if (result != null) {
        await _checkTicket(result!.code);
      }
    });
  }

  Future<void> _checkTicket(String? ticketCode) async {
    if (ticketCode == null) return;
    final String baseUrl = dotenv.env['BASE_URL'] ?? 'https://defaultapi.com/';

    final response = await http.post(
      Uri.parse('$baseUrl/check_ticket'),
      headers: <String, String>{
        'Content-Type': 'application/json; charset=UTF-8',
      },
      body: jsonEncode(<String, dynamic>{
        'ticket_id': int.parse(ticketCode),
        'bus_number': busNumber,
      }),
    );

    if (response.statusCode == 200) {
      setState(() {
        showSuccess = true;
        showError = false;
      });
      await _getOnBus(ticketCode);
      _startLocationUpdates();
    } else {
      setState(() {
        showError = true;
        showSuccess = false;
      });
    }

    Timer(Duration(seconds: 3), () {
      setState(() {
        showSuccess = false;
        showError = false;
        result = null;
      });
      controller?.resumeCamera();
    });
  }

  Future<void> _getOnBus(String ticketCode) async {
    final String baseUrl = dotenv.env['BASE_URL'] ?? 'https://defaultapi.com/';

    final response = await http.post(
      Uri.parse('$baseUrl/get_on_bus'),
      headers: <String, String>{
        'Content-Type': 'application/json; charset=UTF-8',
      },
      body: jsonEncode(<String, dynamic>{
        'ticket_id': int.parse(ticketCode),
        'bus_id': busId,
      }),
    );

    if (response.statusCode != 200) {
      print('Error on get on bus');
    } else {
      print('Get on bus success');
    }
  }

  void _startLocationUpdates() async {
    await _checkLocationPermission();
    positionTimer = Timer.periodic(Duration(seconds: 30), (timer) async {
      Position position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high);
      await _checkNearbyStations(position);
    });
  }

  Future<void> _checkNearbyStations(Position position) async {
    final String baseUrl = dotenv.env['BASE_URL'] ?? 'https://defaultapi.com/';

    final response = await http.get(
      Uri.parse('$baseUrl/get_station_by_bus_number').replace(queryParameters: {
        'bus_number': busNumber,
      }),
    );

    if (response.statusCode == 200) {
      Map<String, dynamic> data = jsonDecode(response.body);
      List<dynamic> stations = data['stations'];
      for (var station in stations) {
        double distance = Geolocator.distanceBetween(
          position.latitude,
          position.longitude,
          station['latitude'],
          station['longitude'],
        );
        if (distance < 50) {
          await _getOffBus(station['id']);
        }
      }
    } else {
      // Handle error
    }
  }

  Future<void> _getOffBus(int stationId) async {
    final String baseUrl = dotenv.env['BASE_URL'] ?? 'https://defaultapi.com/';

    final response = await http.post(
      Uri.parse('$baseUrl/get_off_bus'),
      headers: <String, String>{
        'Content-Type': 'application/json; charset=UTF-8',
      },
      body: jsonEncode(<String, dynamic>{
        'bus_station_id': stationId,
        'bus_id': busId,
      }),
    );

    if (response.statusCode != 200) {
      // Handle error
    }
  }

  Future<void> _fetchBusInformation() async {
    final String baseUrl = dotenv.env['BASE_URL'] ?? 'https://defaultapi.com/';

    final response = await http.get(
      Uri.parse('$baseUrl/get_bus_information_by_id').replace(queryParameters: {
        'bus_id': busId.toString(),
      }),
      headers: <String, String>{
        'Content-Type': 'application/json; charset=UTF-8',
      },
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      setState(() {
        busNumber = data['bus_number'];
        driverName = data['driver_name'];
      });
    } else {
      // Handle error
    }
  }

  void _showSettingsMenu() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Nhập Bus ID'),
          content: TextField(
            decoration: InputDecoration(labelText: 'Bus ID'),
            keyboardType: TextInputType.number,
            onChanged: (value) {
              busId = int.tryParse(value) ?? busId;
            },
          ),
          actions: <Widget>[
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _fetchBusInformation();
              },
              child: Text('Lưu'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('QR Code Scanner'),
        actions: <Widget>[
          IconButton(
            icon: Icon(Icons.settings),
            onPressed: _showSettingsMenu,
          )
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Column(
                  children: [
                    Icon(FontAwesomeIcons.bus, size: 50, color: Colors.blue),
                    SizedBox(height: 5),
                    Text('Tuyến bus: $busNumber',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                  ],
                ),
                Column(
                  children: [
                    Icon(FontAwesomeIcons.user, size: 50, color: Colors.blue),
                    SizedBox(height: 5),
                    Text('Biển số: $driverName',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            flex: 5,
            child: QRView(
              key: qrKey,
              onQRViewCreated: _onQRViewCreated,
              overlay: QrScannerOverlayShape(
                borderColor: Colors.red,
                borderRadius: 10,
                borderLength: 30,
                borderWidth: 10,
                cutOutSize: 300,
              ),
              cameraFacing: CameraFacing.front,
            ),
          ),
          Expanded(
            flex: 1,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  if (result != null)
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Text('Barcode Type: ${describeEnum(result!.format)}'),
                        Text('Data: ${result!.code}'),
                      ],
                    )
                  else
                    const Text('Scan a code'),
                ],
              ),
            ),
          ),
          if (showSuccess)
            Icon(Icons.check_circle, color: Colors.green, size: 100),
          if (showError) Icon(Icons.error, color: Colors.red, size: 100),
        ],
      ),
    );
  }
}
