BEGIN {
    newrule="{"

    print "{"
    print "  \"description\": \"" ENVIRON["header_oneline"] "\","
    print "  \"name\": \"DoH-IP-blocklists\","
    print "  \"rules\": ["
}

{
    print "    " newrule
    print "      \"action\": \"deny\","
    print "      \"notes\": \"\","
    print "      \"process\": \"any\","
    print "      \"remote-domains\": \"" $3 "\""
    print "    }"
    newrule=", {"
}


END {
    print "  ]"
    print "}"
}
