## Compile with the desired naming flag to inspect complete record layouts.
import sigils

echo "SigilName=", sizeof(SigilName)
echo "SigilRequest=", sizeof(SigilRequest)
echo "SubscriptionEntry=", sizeof(SubscriptionEntry)
echo "Invocation=", sizeof(Invocation)
echo "Selector[int,int]=", sizeof(Selector[int, int])
echo "ProtocolRequirement=", sizeof(ProtocolRequirement)
